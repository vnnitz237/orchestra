import anthropic, json, os, uuid, logging, re
from orchestra.db import get_pool
from orchestra.broadcast import broadcast
from orchestra.github_client import read_repo_context

logger = logging.getLogger(__name__)

async def process_order(order_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', order_id)
        if not order:
            return
        project_id = str(order['project_id'])
        project = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)

        await conn.execute(
            'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
            'analyzing', order_id)
        await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "analyzing"})

        github_repo = project['github_repo'] if project else None
        repo_context = ""
        if github_repo:
            repo_context = read_repo_context(github_repo)
            logger.info(f"Read GitHub context for {github_repo}: {len(repo_context)} chars")

        client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

        repo_section = f"\n\nRepository context:\n{repo_context}" if repo_context else ""
        prompt = f"""You are a software project coordinator. Break this order into 3-5 specific, actionable development tasks.

Order: {order['title']}
Description: {order['description']}{repo_section}

Return ONLY a JSON array (no markdown, no explanation):
[{{"title": "...", "description": "detailed description of what to implement", "agent_type": "developer"}}]"""

        try:
            msg = client.messages.create(
                model="claude-opus-4-5", max_tokens=2048,
                messages=[{"role": "user", "content": prompt}])
            text = msg.content[0].text.strip()
            text = re.sub(r'^```[a-z]*\n?', '', text)
            text = re.sub(r'\n?```$', '', text)
            tasks = json.loads(text)
        except Exception as e:
            logger.error(f"Coordinator failed order={order_id}: {e}")
            await conn.execute(
                'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
                'failed', order_id)
            await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "failed"})
            return

        task_ids = []
        for i, t in enumerate(tasks):
            task_id = str(uuid.uuid4())
            await conn.execute("""
                INSERT INTO task (id, order_id, project_id, title, description, agent_type, status, sort_order)
                VALUES ($1,$2,$3,$4,$5,$6,'pending',$7)
            """, task_id, order_id, project_id,
                t.get('title', 'Task'), t.get('description', ''), t.get('agent_type', 'developer'), i)

            await broadcast(project_id, {
                "type": "task_created",
                "task": {"id": task_id, "order_id": order_id, "title": t.get('title'),
                         "description": t.get('description'), "status": "pending", "sort_order": i}
            })
            task_ids.append(task_id)

        await conn.execute(
            'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
            'executing', order_id)
        await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "executing"})

    from orchestra.agents.developer import execute_task
    for task_id in task_ids:
        await execute_task(task_id, project_id)
