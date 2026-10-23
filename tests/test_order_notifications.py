from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, MagicMock

import pytest

from orchestra import notifications, orders


class FakeConnection:
    def __init__(self, *, row=None, value=None):
        self.row = row
        self.value = value
        self.execute_calls = []

    async def fetchrow(self, query, *args):
        return self.row

    async def fetchval(self, query, *args):
        return self.value

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))


class FakePool:
    def __init__(self, connection):
        self.connection = connection

    @asynccontextmanager
    async def acquire(self):
        yield self.connection


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("counts", "expected"),
    [
        ({"total": 3, "active": 0, "failed": 0}, "completed"),
        ({"total": 3, "active": 0, "failed": 1}, "failed"),
    ],
)
async def test_finalize_order_chooses_status_from_tasks(monkeypatch, counts, expected):
    async def fake_get_pool():
        return FakePool(FakeConnection(row=counts))

    final = AsyncMock(return_value=True)
    monkeypatch.setattr(orders, "get_pool", fake_get_pool)
    monkeypatch.setattr(orders, "set_order_final_status", final)

    assert await orders.finalize_order_if_done("order-id", "project-id") is True
    final.assert_awaited_once_with("order-id", "project-id", expected)


@pytest.mark.asyncio
async def test_finalize_order_waits_for_active_tasks(monkeypatch):
    async def fake_get_pool():
        return FakePool(FakeConnection(row={"total": 3, "active": 1, "failed": 0}))

    final = AsyncMock()
    monkeypatch.setattr(orders, "get_pool", fake_get_pool)
    monkeypatch.setattr(orders, "set_order_final_status", final)

    assert await orders.finalize_order_if_done("order-id", "project-id") is False
    final.assert_not_awaited()


@pytest.mark.asyncio
async def test_final_status_broadcasts_and_notifies_only_after_update(monkeypatch):
    async def fake_get_pool():
        return FakePool(FakeConnection(value="order-id"))

    broadcast = AsyncMock()
    notify = AsyncMock()
    monkeypatch.setattr(orders, "get_pool", fake_get_pool)
    monkeypatch.setattr(orders, "broadcast", broadcast)
    monkeypatch.setattr(orders, "notify_order", notify)

    assert await orders.set_order_final_status("order-id", "project-id", "completed") is True
    broadcast.assert_awaited_once()
    notify.assert_awaited_once_with("order-id", "completed")


def test_send_email_uses_tls_and_authentication(monkeypatch):
    smtp = MagicMock()
    smtp.__enter__.return_value = smtp
    smtp_class = MagicMock(return_value=smtp)
    monkeypatch.setattr(notifications.smtplib, "SMTP", smtp_class)
    monkeypatch.setenv("SMTP_HOST", "smtp.example.com")
    monkeypatch.setenv("SMTP_PORT", "587")
    monkeypatch.setenv("SMTP_USER", "user")
    monkeypatch.setenv("SMTP_PASSWORD", "secret")
    monkeypatch.setenv("SMTP_FROM", "orchestra@example.com")

    notifications._send_email("person@example.com", "Assunto", "Mensagem")

    smtp_class.assert_called_once_with("smtp.example.com", 587, timeout=20)
    smtp.starttls.assert_called_once_with()
    smtp.login.assert_called_once_with("user", "secret")
    smtp.send_message.assert_called_once()
