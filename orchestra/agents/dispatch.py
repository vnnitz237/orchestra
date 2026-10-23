from orchestra.db import get_pool


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

    await execute_task(task_id, project_id)
