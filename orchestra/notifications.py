import asyncio
import logging
import os
import smtplib
from email.message import EmailMessage

from orchestra.db import get_pool

logger = logging.getLogger(__name__)


def _send_email(recipient: str, subject: str, body: str) -> None:
    host = os.environ.get("SMTP_HOST")
    sender = os.environ.get("SMTP_FROM") or os.environ.get("SMTP_USER")
    if not host or not sender:
        raise RuntimeError("SMTP_HOST e SMTP_FROM (ou SMTP_USER) não configurados")

    port = int(os.environ.get("SMTP_PORT", "587"))
    username = os.environ.get("SMTP_USER")
    password = os.environ.get("SMTP_PASSWORD")
    use_tls = os.environ.get("SMTP_USE_TLS", "true").lower() in ("1", "true", "yes")
    message = EmailMessage()
    message["From"] = sender
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(body)

    with smtplib.SMTP(host, port, timeout=20) as smtp:
        if use_tls:
            smtp.starttls()
        if username:
            smtp.login(username, password or "")
        smtp.send_message(message)


async def notify_order(order_id: str, order_status: str) -> None:
    """Send one email per final order status and persist the delivery result."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        data = await conn.fetchrow("""
            SELECT o.title, p.name AS project_name, p.notification_email
            FROM "order" o JOIN project p ON p.id=o.project_id
            WHERE o.id=$1
        """, order_id)
        if not data or not data['notification_email']:
            return
        delivery_id = await conn.fetchval("""
            INSERT INTO notification_delivery
                (order_id, channel, recipient, order_status, status)
            VALUES ($1, 'email', $2, $3, 'pending')
            ON CONFLICT (order_id, channel, recipient, order_status) DO NOTHING
            RETURNING id
        """, order_id, data['notification_email'], order_status)
        if not delivery_id:
            return

    label = "concluído" if order_status == "completed" else "falhou"
    subject = f"Orchestra: pedido {label} — {data['title']}"
    body = (
        f"Projeto: {data['project_name']}\n"
        f"Pedido: {data['title']}\n"
        f"Status: {label}\n"
    )
    try:
        await asyncio.to_thread(_send_email, data['notification_email'], subject, body)
    except Exception as exc:
        error = str(exc)[:500]
        logger.warning("Email notification failed order=%s: %s", order_id, error)
        async with pool.acquire() as conn:
            await conn.execute("""
                UPDATE notification_delivery SET status='failed', error=$1
                WHERE id=$2
            """, error, delivery_id)
        return

    async with pool.acquire() as conn:
        await conn.execute("""
            UPDATE notification_delivery SET status='sent', sent_at=NOW()
            WHERE id=$1
        """, delivery_id)

