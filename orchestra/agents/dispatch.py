import asyncio, logging
from orchestra.db import get_pool
from orchestra.broadcast import broadcast

logger = logging.getLogger(__name__)
_MAX_RETRIES = 2


async def dispatch_task(task_id: str, project_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT agent_type FROM task WHERE id=$1", task_id)
    agent_type = (row['agent_type'] if row else None) or 'developer'

    if agent_type == 'architect':
        from orchestra.agents.architect import execute_task
    elif agent_type == 'tester':
        from orchestra.agents.tester import execute_task
    else:
        from orchestra.agents.developer import execute_task

    for attempt in range(_MAX_RETRIES + 1):
        if attempt > 0:
            wait = 2 ** attempt
            await broadcast(project_id, {"type": "activity", "task_id": task_id,
                "msg": f"Tentativa {attempt + 1}/{_MAX_RETRIES + 1} — aguardando {wait}s…"})
            await asyncio.sleep(wait)
            pool = await get_pool()
            async with pool.acquire() as conn:
                await conn.execute(
                    "UPDATE task SET status='pending', updated_at=NOW() WHERE id=$1 AND status='failed'",
                    task_id)

        await execute_task(task_id, project_id)

        pool = await get_pool()
        async with pool.acquire() as conn:
            t = await conn.fetchrow("SELECT status FROM task WHERE id=$1", task_id)
        status = t['status'] if t else 'failed'
        if status == 'completed' or status == 'failed' and attempt >= _MAX_RETRIES:
            break

    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT order_id FROM task WHERE id=$1", task_id)
    if task:
        from orchestra.orders import finalize_order_if_done
        await finalize_order_if_done(str(task['order_id']), project_id)
