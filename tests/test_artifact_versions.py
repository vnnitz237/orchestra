from contextlib import asynccontextmanager
from unittest.mock import patch

import pytest
from fastapi import HTTPException

from orchestra.api import main
from orchestra.db import create_artifact
from orchestra import sandbox


class FakeConnection:
    def __init__(self, *, rows=None, row=None, value=None):
        self.rows = rows or []
        self.row = row
        self.value = value
        self.execute_calls = []
        self.fetch_calls = []
        self.fetchrow_calls = []

    @asynccontextmanager
    async def transaction(self):
        yield

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))

    async def fetchval(self, query, *args):
        self.fetch_calls.append((query, args))
        return self.value

    async def fetch(self, query, *args):
        self.fetch_calls.append((query, args))
        return self.rows

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        return self.row


class FakePool:
    def __init__(self, connection):
        self.connection = connection

    @asynccontextmanager
    async def acquire(self):
        yield self.connection


@pytest.mark.asyncio
async def test_create_artifact_uses_next_version_and_path_scoped_lock():
    conn = FakeConnection(value=3)

    with patch("orchestra.db.uuid.uuid4", return_value="artifact-id"):
        artifact = await create_artifact(
            conn, "project-id", "task-id", "code", "src/app.py", b"print('ok')")

    assert artifact == {"id": "artifact-id", "path": "src/app.py", "version": 3}
    assert conn.execute_calls[0][1] == ("artifact:task-id:code:src/app.py",)
    insert_query, insert_args = conn.execute_calls[1]
    assert "INSERT INTO artifact" in insert_query
    assert insert_args == (
        "artifact-id", "project-id", "task-id", "code", "src/app.py", b"print('ok')", 3)


@pytest.mark.asyncio
async def test_project_artifacts_returns_only_latest_version(monkeypatch):
    latest = {
        "id": "new", "task_id": "task-id", "kind": "code", "path": "app.py",
        "version": 2, "created_at": "now", "version_count": 2,
    }
    conn = FakeConnection(rows=[latest])

    async def fake_get_pool():
        return FakePool(conn)

    monkeypatch.setattr(main, "get_pool", fake_get_pool)
    result = await main.list_artifacts("project-id")

    assert result == [latest]
    query, args = conn.fetch_calls[0]
    assert "ROW_NUMBER() OVER" in query
    assert "ORDER BY a.version DESC" in query
    assert "WHERE latest_rank=1" in query
    assert args == ("project-id",)


@pytest.mark.asyncio
async def test_artifact_versions_are_returned_newest_first(monkeypatch):
    versions = [
        {"id": "v2", "version": 2},
        {"id": "v1", "version": 1},
    ]
    conn = FakeConnection(
        row={"task_id": "task-id", "kind": "spec", "path": "docs/spec.md"},
        rows=versions,
    )

    async def fake_get_pool():
        return FakePool(conn)

    monkeypatch.setattr(main, "get_pool", fake_get_pool)
    result = await main.list_artifact_versions("v2")

    assert result == versions
    query, args = conn.fetch_calls[0]
    assert "ORDER BY version DESC" in query
    assert args == ("task-id", "spec", "docs/spec.md")


@pytest.mark.asyncio
async def test_unknown_artifact_history_returns_404(monkeypatch):
    conn = FakeConnection(row=None)

    async def fake_get_pool():
        return FakePool(conn)

    monkeypatch.setattr(main, "get_pool", fake_get_pool)
    with pytest.raises(HTTPException) as exc:
        await main.list_artifact_versions("missing")

    assert exc.value.status_code == 404


@pytest.mark.asyncio
async def test_sandbox_queries_only_latest_code_versions(monkeypatch):
    conn = FakeConnection(rows=[])

    async def fake_get_pool():
        return FakePool(conn)

    monkeypatch.setattr(sandbox, "get_pool", fake_get_pool)
    result = await sandbox.run_task_artifacts("task-id")

    assert result["ok"] is False
    query, args = conn.fetch_calls[0]
    assert "DISTINCT ON (path)" in query
    assert "version DESC" in query
    assert args == ("task-id",)
