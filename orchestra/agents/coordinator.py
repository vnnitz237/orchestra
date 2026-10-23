import anthropic, json, os, uuid, logging, re
from orchestra.db import get_pool
from orchestra.broadcast import broadcast
from orchestra.github_client import read_repo_context

logger = logging.getLogger(__name__)

# Model routing rules (coordinator decides per task)
# haiku  → docs, configs, simple scripts, tests for trivial components
# sonnet → APIs, features, algorithms, DB schemas, complex components
_SYSTEM = """You are a software project coordinator. Break orders into 3-5 specific, actionable development tasks.

For each task also choose the most cost-effective model:
- "claude-haiku-4-5"  → documentation, README, config files, simple scripts, boilerplate
- "claude-sonnet-4-5" → APIs, core features, algorithms, database schemas, complex components

Return ONLY a valid JSON array, no markdown, no explanation:
[{"title":"...","description":"detailed description","agent_type":"developer","model":"claude-haiku-4-5|claude-sonnet-4-5"}]"""

_ALLOWED_MODELS = {"claude-haiku-4-5", "claude-sonnet-4-5"}

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
        user_prompt = (
            f"Order: {order['title']}\n"
            f"Description: {order['description']}{repo_section}"
        )

        try:
            # Haiku: ~20x cheaper than Opus for JSON planning
            # Prompt caching on system prompt saves 90% after first call
            msg = client.messages.create(
                model="claude-haiku-4-5",
                max_tokens=1024,
                system=[{"type": "text", "text": _SYSTEM, "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": user_prompt}])

            text = msg.content[0].text.strip()
            text = re.sub(r'^```[a-z]*\n?', '', text)
            text = re.sub(r'\n?```$', '', text)
            tasks = json.loads(text)

            tokens_in = msg.usage.input_tokens
            tokens_out = msg.usage.output_tokens
            cost = (tokens_in * 0.25 + tokens_out * 1.25) / 1_000_000
            logger.info(f"Coordinator: {tokens_in}in/{tokens_out}out, ${cost:.5f}")

            # Log model distribution chosen
            model_dist = {}
            for t in tasks:
                m = t.get('model', 'claude-sonnet-4-5')
                model_dist[m] = model_dist.get(m, 0) + 1
            logger.info(f"Model routing: {model_dist}")

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
            # Validate model — fall back to sonnet if coordinator hallucinated a name
            model = t.get('model', 'claude-sonnet-4-5')
            if model not in _ALLOWED_MODELS:
                model = 'claude-sonnet-4-5'

            await conn.execute("""
                INSERT INTO task (id, order_id, project_id, title, description, agent_type, model, status, sort_order)
                VALUES ($1,$2,$3,$4,$5,$6,$7,'pending',$8)
            """, task_id, order_id, project_id,
                t.get('title', 'Task'), t.get('description', ''),
                t.get('agent_type', 'developer'), model, i)

            await broadcast(project_id, {
                "type": "task_created",
                "task": {
                    "id": task_id, "order_id": order_id,
                    "title": t.get('title'), "description": t.get('description'),
                    "status": "pending", "model": model, "sort_order": i
                }
            })
            task_ids.append(task_id)

        await conn.execute(
            'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
            'executing', order_id)
        await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "executing"})

    from orchestra.agents.developer import execute_task
    for task_id in task_ids:
        await execute_task(task_id, project_id)
