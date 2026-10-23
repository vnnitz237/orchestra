import anthropic, json, os, re, uuid, logging
from orchestra.db import get_pool
from orchestra.broadcast import broadcast
from orchestra.github_client import create_pr, slug

logger = logging.getLogger(__name__)

# Cached system prompt — saves 90% on input tokens after first call
_SYSTEM = """You are an expert software developer. Implement tasks completely with production-quality code.

For each file, use this EXACT format:
### `path/to/filename.ext`
```language
<file contents here>
```

Generate complete, working code with proper error handling. No placeholders."""

def _parse_files(text: str):
    files = []
    pattern = r'###\s+`([^`\n]+)`\s*\n```(?:\w+)?\n(.*?)```'
    for path, content in re.findall(pattern, text, re.DOTALL):
        files.append({"path": path.strip(), "content": content.strip()})
    if not files:
        blocks = re.findall(r'```(?:python|javascript|typescript|sql|sh|bash|yaml|json|go|rust)?\n(.*?)```', text, re.DOTALL)
        for i, c in enumerate(blocks):
            ext = "py"
            if any(kw in c for kw in ["import React", "const ", "useState", "export default"]):
                ext = "jsx"
            elif "SELECT " in c or "CREATE TABLE" in c:
                ext = "sql"
            files.append({"path": f"generated/file_{i+1}.{ext}", "content": c.strip()})
    return files

# Pricing for claude-sonnet-4-5 per million tokens
_PRICE_IN  = 3.0   # $3/M input tokens
_PRICE_OUT = 15.0  # $15/M output tokens

async def execute_task(task_id: str, project_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT * FROM task WHERE id=$1", task_id)
        if not task:
            return
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', task['order_id'])
        project = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)

        await conn.execute("UPDATE task SET status='executing', updated_at=NOW() WHERE id=$1", task_id)
        await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "executing"})
        await broadcast(project_id, {"type": "activity", "task_id": task_id, "msg": f"Developer starting: {task['title']}"})

        exec_id = str(uuid.uuid4())
        await conn.execute("""
            INSERT INTO execution (id, task_id, agent_type, status, input)
            VALUES ($1,$2,$3,'running',$4)
        """, exec_id, task_id, 'developer',
            json.dumps({"title": task['title'], "description": task['description']}))

        client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
        project_name = project['name'] if project else "Software project"
        github_repo = project['github_repo'] if project else None
        order_title = order['title'] if order else ""
        order_id = str(task['order_id'])

        repo_hint = f" (GitHub: {github_repo})" if github_repo else ""
        user_prompt = (
            f"Project: {project_name}{repo_hint}\n"
            f"Order: {order_title}\n"
            f"Task: {task['title']}\n"
            f"Details: {task['description']}"
        )

        response_chunks = []
        tokens_in = 0
        tokens_out = 0
        cost = 0.0

        try:
            # Sonnet: ~5x cheaper than Opus, still excellent for code generation
            # Streaming: activity feed shows progress in real time
            # Prompt caching on system prompt: 90% discount after first call
            with client.messages.stream(
                model="claude-sonnet-4-5",
                max_tokens=4096,
                system=[{"type": "text", "text": _SYSTEM, "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": user_prompt}]
            ) as stream:
                char_buf = ""
                for text_delta in stream.text_stream:
                    response_chunks.append(text_delta)
                    char_buf += text_delta
                    # Broadcast every ~120 chars to avoid flooding WebSocket
                    if len(char_buf) >= 120:
                        preview = char_buf.replace('\n', ' ').strip()[:80]
                        if preview:
                            await broadcast(project_id, {
                                "type": "activity", "task_id": task_id,
                                "msg": f"Writing: {preview}…"
                            })
                        char_buf = ""

                final = stream.get_final_message()
                tokens_in = final.usage.input_tokens
                tokens_out = final.usage.output_tokens
                cache_hit = getattr(final.usage, 'cache_read_input_tokens', 0)
                cost = (tokens_in * _PRICE_IN + tokens_out * _PRICE_OUT) / 1_000_000

        except Exception as e:
            logger.error(f"Developer failed task={task_id}: {e}")
            await conn.execute("UPDATE task SET status='failed', updated_at=NOW() WHERE id=$1", task_id)
            await conn.execute("UPDATE execution SET status='failed', finished_at=NOW() WHERE id=$1", exec_id)
            await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "failed"})
            return

        response_text = "".join(response_chunks)
        files = _parse_files(response_text)
        await broadcast(project_id, {"type": "activity", "task_id": task_id,
            "msg": f"Generated {len(files)} file(s) — ${cost:.4f} ({tokens_in+tokens_out} tokens)"})

        artifact_ids = []
        for f in files:
            art_id = str(uuid.uuid4())
            await conn.execute("""
                INSERT INTO artifact (id, project_id, task_id, kind, path, content)
                VALUES ($1,$2,$3,'code',$4,$5)
            """, art_id, project_id, task_id, f['path'], f['content'].encode())
            artifact_ids.append({"id": art_id, "path": f['path']})

        await conn.execute("""
            UPDATE execution SET status='completed', output=$1, cost_usd=$2, tokens_used=$3, finished_at=NOW()
            WHERE id=$4
        """, response_text[:8000], cost, tokens_in + tokens_out, exec_id)

        pr_url = None
        if github_repo and files:
            try:
                await broadcast(project_id, {"type": "activity", "task_id": task_id, "msg": f"Opening PR on {github_repo}..."})
                branch_name = f"orchestra/{order_id[:8]}/{slug(task['title'])}"
                pr_body = (
                    f"Generated by Orchestra\n\n"
                    f"**Order:** {order_title}\n"
                    f"**Task:** {task['title']}\n\n"
                    f"{task['description'] or ''}"
                )
                pr_url = create_pr(github_repo, branch_name, task['title'], pr_body, files)
                logger.info(f"PR created: {pr_url}")
            except Exception as pr_err:
                logger.warning(f"PR creation failed for task={task_id}: {pr_err}")

        result = json.dumps({"artifacts": artifact_ids, "files": len(files), "pr_url": pr_url})
        await conn.execute(
            "UPDATE task SET status='completed', result=$1, github_pr_url=$2, updated_at=NOW() WHERE id=$3",
            result, pr_url, task_id)
        await broadcast(project_id, {
            "type": "task_updated", "task_id": task_id,
            "status": "completed", "artifacts": artifact_ids,
            "github_pr_url": pr_url,
            "cost_usd": float(cost),
            "tokens": tokens_in + tokens_out
        })

    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT order_id FROM task WHERE id=$1", task_id)
        if not task:
            return
        remaining = await conn.fetchval("""
            SELECT COUNT(*) FROM task
            WHERE order_id=$1 AND status NOT IN ('completed','failed')
        """, task['order_id'])
        if remaining == 0:
            await conn.execute(
                'UPDATE "order" SET status=\'completed\', updated_at=NOW() WHERE id=$1',
                task['order_id'])
            await broadcast(project_id, {
                "type": "order_updated",
                "order_id": str(task['order_id']),
                "status": "completed"
            })
