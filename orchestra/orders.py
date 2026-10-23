from orchestra.broadcast import broadcast
from orchestra.db import get_pool
from orchestra.notifications import notify_order


async def set_order_final_status(order_id: str, project_id: str, status: str) -> bool:
    if status not in ("completed", "failed"):
        raise ValueError("Final order status must be completed or failed")
    pool = await get_pool()
    async with pool.acquire() as conn:
        updated = await conn.fetchval("""
            UPDATE "order" SET status=$1, updated_at=NOW()
            WHERE id=$2 AND status NOT IN ('completed', 'failed')
            RETURNING id
        """, status, order_id)
    if not updated:
        return False
    await broadcast(project_id, {
        "type": "order_updated", "order_id": order_id, "status": status,
    })
    await notify_order(order_id, status)
    return True


async def finalize_order_if_done(order_id: str, project_id: str) -> bool:
    pool = await get_pool()
    async with pool.acquire() as conn:
        counts = await conn.fetchrow("""
            SELECT COUNT(*) AS total,
                   COUNT(*) FILTER (WHERE status NOT IN ('completed','failed')) AS active,
                   COUNT(*) FILTER (WHERE status='failed') AS failed
            FROM task WHERE order_id=$1
        """, order_id)
    if not counts or counts['total'] == 0 or counts['active'] > 0:
        return False
    status = "failed" if counts['failed'] > 0 else "completed"
    return await set_order_final_status(order_id, project_id, status)

