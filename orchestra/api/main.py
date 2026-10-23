import asyncio, io, json, logging, os, re, zipfile
from contextlib import asynccontextmanager, suppress
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import PlainTextResponse, StreamingResponse
from pydantic import BaseModel
from typing import Optional
import redis.asyncio as aioredis

from orchestra.db import get_pool, close_pool
from orchestra.ws import manager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

async def redis_relay():
    redis = aioredis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379"))
    pubsub = redis.pubsub()
    await pubsub.psubscribe("project:*")
    try:
        async for msg in pubsub.listen():
            if msg["type"] != "pmessage":
                continue
            channel = msg["channel"]
            if isinstance(channel, bytes):
                channel = channel.decode()
            project_id = channel.split(":", 1)[1]
            data = msg["data"]
            if isinstance(data, bytes):
                data = data.decode()
            try:
                await manager.broadcast_json(project_id, json.loads(data))
            except Exception as e:
                logger.error(f"relay error: {e}")
    finally:
        await pubsub.aclose()
        await redis.aclose()

@asynccontextmanager
async def lifespan(app: FastAPI):
    pool = await get_pool()
    # Auto-migrate: add columns introduced after initial schema
    async with pool.acquire() as conn:
        await conn.execute(
            "ALTER TABLE task ADD COLUMN IF NOT EXISTS model TEXT NOT NULL DEFAULT 'claude-sonnet-4-5'"
        )
        await conn.execute(
            "ALTER TABLE task ADD COLUMN IF NOT EXISTS depends_on JSONB NOT NULL DEFAULT '[]'"
        )
        await conn.execute(
            "ALTER TABLE project ADD COLUMN IF NOT EXISTS autonomy TEXT NOT NULL DEFAULT 'delegated'"
        )
        await conn.execute(
            "ALTER TABLE project ADD COLUMN IF NOT EXISTS budget_usd DECIMAL(10,2)"
        )
        await conn.execute(
            "ALTER TABLE project ADD COLUMN IF NOT EXISTS notification_email TEXT"
        )
        await conn.execute(
            "ALTER TABLE artifact ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1"
        )
        await conn.execute("""
            WITH numbered AS (
                SELECT id, ROW_NUMBER() OVER (
                    PARTITION BY task_id, kind, path ORDER BY version, created_at, id
                ) AS artifact_version
                FROM artifact
            )
            UPDATE artifact a SET version = numbered.artifact_version
            FROM numbered WHERE a.id = numbered.id AND a.version <> numbered.artifact_version
        """)
        await conn.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS artifact_task_path_version_idx
            ON artifact (task_id, kind, path, version)
        """)
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS notification_delivery (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                order_id UUID NOT NULL REFERENCES "order"(id) ON DELETE CASCADE,
                channel TEXT NOT NULL, recipient TEXT NOT NULL,
                order_status TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
                error TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), sent_at TIMESTAMPTZ,
                UNIQUE (order_id, channel, recipient, order_status)
            )
        """)
    relay_task = asyncio.create_task(redis_relay())
    try:
        yield
    finally:
        relay_task.cancel()
        with suppress(asyncio.CancelledError):
            await relay_task
        await close_pool()

app = FastAPI(lifespan=lifespan, title="Orchestra API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class ProjectCreate(BaseModel):
    name: str
    description: Optional[str] = None
    github_repo: Optional[str] = None
    autonomy: Optional[str] = "delegated"
    budget_usd: Optional[float] = None
    notification_email: Optional[str] = None

class ProjectUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    github_repo: Optional[str] = None
    autonomy: Optional[str] = None
    budget_usd: Optional[float] = None
    notification_email: Optional[str] = None

class OrderCreate(BaseModel):
    title: str
    description: str

@app.get("/api/projects")
async def list_projects():
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT p.*, COUNT(DISTINCT o.id) AS order_count,
                   COALESCE(SUM(e.cost_usd), 0) AS total_cost
            FROM project p
            LEFT JOIN "order" o ON o.project_id = p.id
            LEFT JOIN task t ON t.project_id = p.id
            LEFT JOIN execution e ON e.task_id = t.id AND e.status = 'completed'
            GROUP BY p.id ORDER BY p.created_at DESC
        """)
        return [dict(r) for r in rows]

@app.post("/api/projects", status_code=201)
async def create_project(body: ProjectCreate):
    autonomy = body.autonomy if body.autonomy in ('planning', 'supervised', 'delegated') else 'delegated'
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "INSERT INTO project (name, description, github_repo, autonomy, budget_usd, notification_email) VALUES ($1,$2,$3,$4,$5,$6) RETURNING *",
            body.name, body.description, body.github_repo, autonomy, body.budget_usd,
            body.notification_email)
        return dict(row)

@app.patch("/api/projects/{project_id}")
async def update_project(project_id: str, body: ProjectUpdate):
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)
        if not row:
            raise HTTPException(404, "Not found")
        name = body.name if body.name is not None else row['name']
        desc = body.description if body.description is not None else row['description']
        repo = body.github_repo if body.github_repo is not None else row['github_repo']
        autonomy = body.autonomy if body.autonomy in ('planning','supervised','delegated') else row['autonomy']
        budget = body.budget_usd if body.budget_usd is not None else row['budget_usd']
        notification_email = (body.notification_email.strip() or None
                              if body.notification_email is not None else row['notification_email'])
        updated = await conn.fetchrow(
            "UPDATE project SET name=$1, description=$2, github_repo=$3, autonomy=$4, budget_usd=$5, notification_email=$6 WHERE id=$7 RETURNING *",
            name, desc, repo, autonomy, budget, notification_email, project_id)
        return dict(updated)

@app.get("/api/projects/{project_id}")
async def get_project(project_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)
        if not row:
            raise HTTPException(404, "Not found")
        orders = await conn.fetch(
            'SELECT * FROM "order" WHERE project_id=$1 ORDER BY created_at DESC', project_id)
        # Total cost for project
        cost_row = await conn.fetchrow("""
            SELECT COALESCE(SUM(e.cost_usd),0) AS total_cost
            FROM execution e
            JOIN task t ON t.id = e.task_id
            JOIN "order" o ON o.id = t.order_id
            WHERE o.project_id=$1 AND e.status='completed'
        """, project_id)
        return {**dict(row), "orders": [dict(o) for o in orders],
                "total_cost": float(cost_row['total_cost'])}

@app.post("/api/projects/{project_id}/orders", status_code=201)
async def create_order(project_id: str, body: OrderCreate, bg: BackgroundTasks):
    pool = await get_pool()
    async with pool.acquire() as conn:
        project = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)
        if not project:
            raise HTTPException(404, "Project not found")
        row = await conn.fetchrow("""
            INSERT INTO "order" (project_id, title, description, status)
            VALUES ($1,$2,$3,'pending') RETURNING *
        """, project_id, body.title, body.description)
        order = dict(row)
    bg.add_task(_run_coordinator, str(row['id']))
    return order

async def _run_coordinator(order_id: str):
    from orchestra.agents.coordinator import process_order
    try:
        await process_order(order_id)
    except Exception as e:
        logger.error(f"coordinator error order={order_id}: {e}")

@app.get("/api/orders/{order_id}/tasks")
async def get_tasks(order_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT t.id, t.order_id, t.project_id, t.title, t.description, t.agent_type,
                   t.model, t.status, t.result, t.github_pr_url, t.sort_order,
                   t.created_at, t.updated_at,
                   COALESCE(SUM(e.cost_usd), 0)     AS cost_usd,
                   COALESCE(SUM(e.tokens_used), 0)  AS tokens_used,
                   (SELECT output FROM execution
                    WHERE task_id = t.id AND status = 'failed'
                    ORDER BY created_at DESC LIMIT 1) AS last_error
            FROM task t
            LEFT JOIN execution e ON e.task_id = t.id AND e.status = 'completed'
            WHERE t.order_id = $1
            GROUP BY t.id
            ORDER BY t.sort_order
        """, order_id)
        return [dict(r) for r in rows]

@app.post("/api/tasks/{task_id}/retry")
async def retry_task(task_id: str, bg: BackgroundTasks):
    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT * FROM task WHERE id=$1", task_id)
        if not task:
            raise HTTPException(404, "Task not found")
        if task['status'] not in ('failed',):
            raise HTTPException(400, f"Task status is '{task['status']}', only 'failed' tasks can be retried")
        # Check budget before retrying
        project = await conn.fetchrow("SELECT * FROM project WHERE id=$1", task['project_id'])
        if project and project['budget_usd']:
            spent = await conn.fetchval("""
                SELECT COALESCE(SUM(e.cost_usd),0) FROM execution e
                JOIN task t ON t.id = e.task_id
                JOIN "order" o ON o.id = t.order_id
                WHERE o.project_id=$1 AND e.status='completed'
            """, str(task['project_id']))
            if float(spent or 0) >= float(project['budget_usd']):
                raise HTTPException(402, f"Budget limit ${project['budget_usd']} reached")
        await conn.execute("UPDATE task SET status='pending', updated_at=NOW() WHERE id=$1", task_id)
        await conn.execute("""
            UPDATE "order" SET status='executing', updated_at=NOW()
            WHERE id=$1 AND status IN ('completed','failed')
        """, str(task['order_id']))
    bg.add_task(_run_task, task_id, str(task['project_id']))
    return {"status": "retrying", "task_id": task_id}

async def _run_task(task_id: str, project_id: str):
    from orchestra.agents.dispatch import dispatch_task
    try:
        await dispatch_task(task_id, project_id)
    except Exception as e:
        logger.error(f"retry task={task_id}: {e}")

# Approve pending order execution (autonomy=planning mode)
@app.post("/api/orders/{order_id}/approve")
async def approve_order(order_id: str, bg: BackgroundTasks):
    pool = await get_pool()
    async with pool.acquire() as conn:
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', order_id)
        if not order:
            raise HTTPException(404, "Order not found")
        if order['status'] != 'awaiting_approval':
            raise HTTPException(400, f"Order status is '{order['status']}', expected 'awaiting_approval'")
        tasks = await conn.fetch(
            "SELECT id, depends_on FROM task WHERE order_id=$1 AND status='pending' ORDER BY sort_order", order_id)
        await conn.execute(
            'UPDATE "order" SET status=\'executing\', updated_at=NOW() WHERE id=$1', order_id)
        import json as _json
        task_ids = [str(t['id']) for t in tasks]
        task_deps = {str(t['id']): _json.loads(t['depends_on'] or '[]') for t in tasks}
        project_id = str(order['project_id'])

    from orchestra.broadcast import broadcast
    await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "executing"})
    bg.add_task(_run_approved_tasks, task_ids, task_deps, project_id)
    return {"status": "approved", "tasks": len(task_ids)}

async def _run_approved_tasks(task_ids: list, task_deps: dict, project_id: str):
    from orchestra.agents.coordinator import _execute_dag
    try:
        await _execute_dag(task_ids, task_deps, project_id)
    except Exception as e:
        logger.error(f"approved tasks project={project_id}: {e}")

@app.get("/api/orders/{order_id}/cost")
async def get_order_cost(order_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("""
            SELECT COALESCE(SUM(e.cost_usd),0) AS total_cost,
                   COALESCE(SUM(e.tokens_used),0) AS total_tokens,
                   COUNT(e.id) AS executions
            FROM execution e
            JOIN task t ON t.id = e.task_id
            WHERE t.order_id=$1 AND e.status='completed'
        """, order_id)
        return dict(row)

@app.get("/api/orders/{order_id}/notifications")
async def get_order_notifications(order_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT id, channel, recipient, order_status, status, error, created_at, sent_at
            FROM notification_delivery WHERE order_id=$1 ORDER BY created_at DESC
        """, order_id)
        return [dict(row) for row in rows]

@app.get("/api/projects/{project_id}/artifacts")
async def list_artifacts(project_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT id, task_id, kind, path, version, created_at, version_count
            FROM (
                SELECT a.id, a.task_id, a.kind, a.path, a.version, a.created_at,
                       COUNT(*) OVER (PARTITION BY a.task_id, a.kind, a.path) AS version_count,
                       ROW_NUMBER() OVER (
                           PARTITION BY a.task_id, a.kind, a.path
                           ORDER BY a.version DESC, a.created_at DESC
                       ) AS latest_rank
                FROM artifact a WHERE a.project_id=$1
            ) versioned
            WHERE latest_rank=1 ORDER BY created_at
        """, project_id)
        return [dict(r) for r in rows]

@app.get("/api/artifacts/{artifact_id}/versions")
async def list_artifact_versions(artifact_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        artifact = await conn.fetchrow(
            "SELECT task_id, kind, path FROM artifact WHERE id=$1", artifact_id)
        if not artifact:
            raise HTTPException(404, "Not found")
        rows = await conn.fetch("""
            SELECT id, task_id, kind, path, version, created_at
            FROM artifact
            WHERE task_id=$1 AND kind=$2 AND path=$3
            ORDER BY version DESC
        """, artifact['task_id'], artifact['kind'], artifact['path'])
        return [dict(r) for r in rows]

def _make_zip(rows, filename: str) -> StreamingResponse:
    files: dict[str, bytes] = {}
    for row in rows:
        files[row['path']] = row['content'] or b''
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        for path, content in files.items():
            zf.writestr(path, content)
    buf.seek(0)
    safe = re.sub(r'[^a-z0-9._-]', '-', filename.lower()).strip('-')
    return StreamingResponse(buf, media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{safe}.zip"'})

@app.get("/api/projects/{project_id}/artifacts/download")
async def download_project_artifacts(project_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        project = await conn.fetchrow("SELECT name FROM project WHERE id=$1", project_id)
        if not project:
            raise HTTPException(404, "Not found")
        rows = await conn.fetch("""
            SELECT DISTINCT ON (task_id, kind, path) path, content
            FROM artifact WHERE project_id=$1
            ORDER BY task_id, kind, path, version DESC, created_at DESC
        """, project_id)
    return _make_zip(rows, f"orchestra-{project['name']}")

@app.get("/api/orders/{order_id}/artifacts/download")
async def download_order_artifacts(order_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        order = await conn.fetchrow('SELECT title FROM "order" WHERE id=$1', order_id)
        if not order:
            raise HTTPException(404, "Not found")
        rows = await conn.fetch("""
            SELECT DISTINCT ON (a.task_id, a.kind, a.path) a.path, a.content
            FROM artifact a
            JOIN task t ON t.id = a.task_id
            WHERE t.order_id=$1
            ORDER BY a.task_id, a.kind, a.path, a.version DESC, a.created_at DESC
        """, order_id)
    return _make_zip(rows, f"orchestra-{order['title']}")

@app.get("/api/artifacts/{artifact_id}/content")
async def get_artifact_content(artifact_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT content, path FROM artifact WHERE id=$1", artifact_id)
        if not row or not row['content']:
            raise HTTPException(404, "Not found")
        return PlainTextResponse(row['content'].decode(errors='replace'))

@app.websocket("/ws/{project_id}")
async def ws_endpoint(ws: WebSocket, project_id: str):
    await manager.connect(ws, project_id)
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(ws, project_id)

@app.post("/api/tasks/{task_id}/execute")
async def execute_sandbox(task_id: str, bg: BackgroundTasks):
    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT * FROM task WHERE id=$1", task_id)
        if not task:
            raise HTTPException(404, "Task not found")
        if task['status'] != 'completed':
            raise HTTPException(400, "Task precisa estar concluída para executar")
        if task['agent_type'] != 'developer':
            raise HTTPException(400, "Apenas tasks do agente developer podem ser executadas")
    bg.add_task(_run_sandbox, task_id, str(task['project_id']))
    return {"status": "running", "task_id": task_id}

async def _run_sandbox(task_id: str, project_id: str):
    from orchestra.sandbox import run_task_artifacts
    from orchestra.broadcast import broadcast
    await broadcast(project_id, {"type": "sandbox_start", "task_id": task_id})
    try:
        result = await run_task_artifacts(task_id)
    except Exception as e:
        result = {"ok": False, "output": str(e)[:500]}
    await broadcast(project_id, {"type": "sandbox_result", "task_id": task_id, **result})

@app.get("/health")
async def health():
    return {"status": "ok"}
