import anthropic, json, os, re, uuid, logging
from orchestra.db import get_pool
from orchestra.broadcast import broadcast

logger = logging.getLogger(__name__)

_SYSTEM = """You are a QA engineer. Write comprehensive test suites for the provided code.

For each test file, use this EXACT format:
### `path/to/test_filename.py`
```python
<test file contents here>
```

Cover: happy path, edge cases, error conditions, boundary values.
Use pytest. Mock external dependencies (DB, HTTP calls, file I/O).
Each test must be runnable with `pytest` with no manual setup beyond installing requirements."""

_MODEL_PRICING = {
    "claude-haiku-4-5":  {"in": 0.25,  "out": 1.25},
    "claude-sonnet-4-5": {"in": 3.0,   "out": 15.0},
}
_DEFAULT_MODEL = "claude-haiku-4-5"


def _parse_files(text: str):
    files = []
    pattern = r'###\s+`([^`\n]+)`\s*\n```(?:\w+)?\n(.*?)```'
    for path, content in re.findall(pattern, text, re.DOTALL):
        files.append({"path": path.strip(), "content": content.strip()})
    return files


async def execute_task(task_id: str, project_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT * FROM task WHERE id=$1", task_id)
        if not task:
            return
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', task['order_id'])
        project = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)

        model = task.get('model') or _DEFAULT_MODEL
        pricing = _MODEL_PRICING.get(model, _MODEL_PRICING[_DEFAULT_MODEL])

        await conn.execute("UPDATE task SET status='executing', updated_at=NOW() WHERE id=$1", task_id)
        await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "executing"})
        await broadcast(project_id, {"type": "activity", "task_id": task_id,
            "msg": f"Tester writing tests [{model.split('-')[1]}]: {task['title']}"})

        exec_id = str(uuid.uuid4())
        await conn.execute("""
            INSERT INTO execution (id, task_id, agent_type, status, input)
            VALUES ($1,$2,$3,'running',$4)
        """, exec_id, task_id, 'tester',
            json.dumps({"title": task['title'], "description": task['description']}))

        client = anthropic.AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
        project_name = project['name'] if project else "Software project"
        order_title = order['title'] if order else ""

        # Fetch code content from dependency tasks
        code_context = ""
        try:
            dep_ids = json.loads(task.get('depends_on') or '[]')
            if dep_ids:
                parts = []
                budget = 6000
                for dep_id in dep_ids:
                    dep = await conn.fetchrow(
                        "SELECT title, result FROM task WHERE id=$1 AND status='completed'", dep_id)
                    if not dep:
                        continue
                    try:
                        r = json.loads(dep['result'] or '{}')
                        for art in r.get('artifacts', [])[:6]:
                            row = await conn.fetchrow(
                                "SELECT path, content FROM artifact WHERE id=$1", art['id'])
                            if not row or not row['content']:
                                continue
                            content_str = row['content'].decode('utf-8', errors='replace')
                            snippet = content_str[:min(1200, budget)]
                            parts.append(f"### `{row['path']}`\n```\n{snippet}\n```")
                            budget -= len(snippet)
                            if budget <= 0:
                                break
                    except Exception:
                        parts.append(f"• {dep['title']}: completed")
                if parts:
                    code_context = "\n\nCode to test:\n" + "\n\n".join(parts)
        except Exception as e:
            logger.warning(f"Could not load dep context for tester task={task_id}: {e}")

        prompt = (
            f"Project: {project_name}\n"
            f"Order: {order_title}\n"
            f"Task: {task['title']}\n"
            f"Details: {task['description']}"
            f"{code_context}"
        )

        tokens_in = tokens_out = 0
        cost = 0.0

        try:
            chunks = []
            async with client.messages.stream(
                model=model, max_tokens=4096,
                system=[{"type": "text", "text": _SYSTEM, "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": prompt}]
            ) as stream:
                char_buf = ""
                async for delta in stream.text_stream:
                    chunks.append(delta)
                    char_buf += delta
                    if len(char_buf) >= 120:
                        preview = char_buf.replace('\n', ' ').strip()[:80]
                        if preview:
                            await broadcast(project_id, {"type": "activity", "task_id": task_id,
                                "msg": f"Writing tests: {preview}…"})
                        char_buf = ""
                final = await stream.get_final_message()
                tokens_in = final.usage.input_tokens
                tokens_out = final.usage.output_tokens

            response_text = "".join(chunks)
            cost = (tokens_in * pricing["in"] + tokens_out * pricing["out"]) / 1_000_000
            files = _parse_files(response_text)

        except Exception as e:
            logger.error(f"Tester failed task={task_id}: {e}")
            await conn.execute("UPDATE task SET status='failed', updated_at=NOW() WHERE id=$1", task_id)
            await conn.execute("UPDATE execution SET status='failed', finished_at=NOW() WHERE id=$1", exec_id)
            await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "failed"})
            return

        await broadcast(project_id, {"type": "activity", "task_id": task_id,
            "msg": f"Tests done — {len(files)} file(s) · ${cost:.4f} ({tokens_in+tokens_out} tokens)"})

        artifact_ids = []
        for f in files:
            art_id = str(uuid.uuid4())
            await conn.execute("""
                INSERT INTO artifact (id, project_id, task_id, kind, path, content)
                VALUES ($1,$2,$3,'test',$4,$5)
            """, art_id, project_id, task_id, f['path'], f['content'].encode())
            artifact_ids.append({"id": art_id, "path": f['path']})

        await conn.execute("""
            UPDATE execution SET status='completed', output=$1, cost_usd=$2, tokens_used=$3, finished_at=NOW()
            WHERE id=$4
        """, response_text[:8000], cost, tokens_in + tokens_out, exec_id)

        result = json.dumps({"artifacts": artifact_ids, "files": len(files)})
        await conn.execute(
            "UPDATE task SET status='completed', result=$1, updated_at=NOW() WHERE id=$2",
            result, task_id)
        await broadcast(project_id, {
            "type": "task_updated", "task_id": task_id,
            "status": "completed", "artifacts": artifact_ids,
            "cost_usd": float(cost), "tokens": tokens_in + tokens_out
        })
