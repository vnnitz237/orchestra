import anthropic, json, os, re, uuid, logging
from orchestra.db import get_pool
from orchestra.broadcast import broadcast

logger = logging.getLogger(__name__)

_SYSTEM = """You are a software architect. Produce technical specifications that developers implement directly.

For each document, use this EXACT format:
### `path/to/filename.md`
```markdown
<document contents here>
```

Each spec must include:
- Architecture overview (components, data flow)
- API contracts (endpoints, request/response schemas with types)
- Database schema (tables, columns, types, relationships)
- File/directory structure
- Key design decisions and rationale

Be precise and implementation-ready. No vague descriptions."""

_MODEL_PRICING = {
    "claude-haiku-4-5":  {"in": 0.25,  "out": 1.25},
    "claude-sonnet-4-5": {"in": 3.0,   "out": 15.0},
}
_DEFAULT_MODEL = "claude-sonnet-4-5"


def _parse_docs(text: str):
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
            "msg": f"Architect designing [{model.split('-')[1]}]: {task['title']}"})

        exec_id = str(uuid.uuid4())
        await conn.execute("""
            INSERT INTO execution (id, task_id, agent_type, status, input)
            VALUES ($1,$2,$3,'running',$4)
        """, exec_id, task_id, 'architect',
            json.dumps({"title": task['title'], "description": task['description']}))

        client = anthropic.AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
        project_name = project['name'] if project else "Software project"
        order_title = order['title'] if order else ""

        prompt = (
            f"Project: {project_name}\n"
            f"Order: {order_title}\n"
            f"Task: {task['title']}\n"
            f"Details: {task['description']}"
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
                async for delta in stream.text_stream:
                    chunks.append(delta)
                final = await stream.get_final_message()
                tokens_in = final.usage.input_tokens
                tokens_out = final.usage.output_tokens

            response_text = "".join(chunks)
            cost = (tokens_in * pricing["in"] + tokens_out * pricing["out"]) / 1_000_000
            docs = _parse_docs(response_text)

        except Exception as e:
            logger.error(f"Architect failed task={task_id}: {e}")
            await conn.execute("UPDATE task SET status='failed', updated_at=NOW() WHERE id=$1", task_id)
            await conn.execute("UPDATE execution SET status='failed', finished_at=NOW() WHERE id=$1", exec_id)
            await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "failed"})
            return

        await broadcast(project_id, {"type": "activity", "task_id": task_id,
            "msg": f"Spec done — {len(docs)} doc(s) · ${cost:.4f} ({tokens_in+tokens_out} tokens)"})

        artifact_ids = []
        for f in docs:
            art_id = str(uuid.uuid4())
            await conn.execute("""
                INSERT INTO artifact (id, project_id, task_id, kind, path, content)
                VALUES ($1,$2,$3,'spec',$4,$5)
            """, art_id, project_id, task_id, f['path'], f['content'].encode())
            artifact_ids.append({"id": art_id, "path": f['path']})

        await conn.execute("""
            UPDATE execution SET status='completed', output=$1, cost_usd=$2, tokens_used=$3, finished_at=NOW()
            WHERE id=$4
        """, response_text[:8000], cost, tokens_in + tokens_out, exec_id)

        result = json.dumps({"artifacts": artifact_ids, "files": len(docs)})
        await conn.execute(
            "UPDATE task SET status='completed', result=$1, updated_at=NOW() WHERE id=$2",
            result, task_id)
        await broadcast(project_id, {
            "type": "task_updated", "task_id": task_id,
            "status": "completed", "artifacts": artifact_ids,
            "cost_usd": float(cost), "tokens": tokens_in + tokens_out
        })
