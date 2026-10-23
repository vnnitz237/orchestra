import anthropic, asyncio, json, os, uuid, logging, re
from orchestra.db import get_pool
from orchestra.broadcast import broadcast
from orchestra.github_client import read_repo_context as _read_repo_context_sync

logger = logging.getLogger(__name__)

_SYSTEM = """Você é um coordenador de projetos de software. Divida os pedidos em 3 a 6 tarefas específicas e acionáveis. Responda sempre em português.

Escolha o agent_type por tarefa:
- "architect"  → documentos de design técnico para funcionalidades complexas (specs de API, schema de BD, arquitetura). Use PRIMEIRO para pedidos que precisam de design claro antes de codar.
- "developer"  → implementação: APIs, funcionalidades, algoritmos, código de banco de dados, componentes de UI
- "tester"     → suítes de teste para código já implementado. SEMPRE depends_on nas tarefas de developer que testa.

Escolha o model por tarefa:
- "claude-haiku-4-5"  → documentação, README, arquivos de config, boilerplate, tarefas de tester
- "claude-sonnet-4-5" → APIs, funcionalidades centrais, algoritmos, componentes complexos, tarefas de architect

Defina dependências com "depends_on": lista de índices 0-based das tarefas que esta deve aguardar.
Tarefas sem dependências rodam em paralelo. Tarefas de tester devem sempre depender das tarefas de developer.

Retorne APENAS um array JSON válido, sem markdown, sem explicação:
[{"title":"...","description":"descrição detalhada em português","agent_type":"architect|developer|tester","model":"claude-haiku-4-5|claude-sonnet-4-5","depends_on":[]}]"""

_ALLOWED_MODELS = {"claude-haiku-4-5", "claude-sonnet-4-5"}
_ALLOWED_AGENTS = {"architect", "developer", "tester"}


async def _execute_dag(task_ids: list, task_deps: dict, project_id: str) -> None:
    """Execute tasks respecting depends_on; parallel where possible."""
    from orchestra.agents.dispatch import dispatch_task as execute_task
    completed: set = set()
    remaining = list(task_ids)

    while remaining:
        wave = [tid for tid in remaining if all(d in completed for d in task_deps.get(tid, []))]
        if not wave:
            logger.error("DAG has circular/unresolvable deps — running remaining sequentially")
            wave = remaining[:1]

        if len(wave) > 1:
            logger.info(f"Running {len(wave)} tasks in parallel: {wave}")
            await asyncio.gather(*[execute_task(tid, project_id) for tid in wave])
        else:
            await execute_task(wave[0], project_id)

        for tid in wave:
            completed.add(tid)
            remaining.remove(tid)


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
            repo_context = await asyncio.to_thread(_read_repo_context_sync, github_repo)
            logger.info(f"Read GitHub context for {github_repo}: {len(repo_context)} chars")

        client = anthropic.AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
        repo_section = f"\n\nRepository context:\n{repo_context}" if repo_context else ""
        user_prompt = (
            f"Order: {order['title']}\n"
            f"Description: {order['description']}{repo_section}"
        )

        try:
            msg = await client.messages.create(
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
            model = t.get('model', 'claude-sonnet-4-5')
            if model not in _ALLOWED_MODELS:
                model = 'claude-sonnet-4-5'
            agent_type = t.get('agent_type', 'developer')
            if agent_type not in _ALLOWED_AGENTS:
                agent_type = 'developer'

            # Validate depends_on: only allow backward references to valid indices
            raw_deps = t.get('depends_on') or []
            dep_indices = [j for j in raw_deps if isinstance(j, int) and 0 <= j < i]

            await conn.execute("""
                INSERT INTO task (id, order_id, project_id, title, description, agent_type, model, status, sort_order, depends_on)
                VALUES ($1,$2,$3,$4,$5,$6,$7,'pending',$8,$9)
            """, task_id, order_id, project_id,
                t.get('title', 'Task'), t.get('description', ''),
                agent_type, model, i,
                json.dumps(dep_indices))  # stored as indices; resolved to IDs below

            await broadcast(project_id, {
                "type": "task_created",
                "task": {
                    "id": task_id, "order_id": order_id,
                    "title": t.get('title'), "description": t.get('description'),
                    "agent_type": agent_type,
                    "status": "pending", "model": model, "sort_order": i,
                    "depends_on": dep_indices
                }
            })
            task_ids.append(task_id)

        # Resolve index-based depends_on to actual task UUIDs
        task_deps: dict = {}
        for i, task_id in enumerate(task_ids):
            raw_deps = tasks[i].get('depends_on') or []
            dep_ids = [task_ids[j] for j in raw_deps if isinstance(j, int) and 0 <= j < i]
            task_deps[task_id] = dep_ids
            await conn.execute(
                "UPDATE task SET depends_on=$1 WHERE id=$2",
                json.dumps(dep_ids), task_id)

        parallel_count = sum(1 for deps in task_deps.values() if not deps)
        logger.info(f"DAG: {len(task_ids)} tasks, {parallel_count} can start immediately")

        autonomy = project['autonomy'] if project else 'delegated'
        if autonomy == 'planning':
            await conn.execute(
                'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
                'awaiting_approval', order_id)
            await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "awaiting_approval"})
            logger.info(f"Order {order_id} awaiting human approval (planning mode)")
            return

        await conn.execute(
            'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
            'executing', order_id)
        await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "executing"})

    await _execute_dag(task_ids, task_deps, project_id)
