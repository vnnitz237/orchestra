import asyncio, json, logging, os
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import PlainTextResponse
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

@asynccontextmanager
async def lifespan(app: FastAPI):
    pool = await get_pool()
    # Auto-migrate: add columns introduced after initial schema
    async with pool.acquire() as conn:
        await conn.execute(
            "ALTER TABLE task ADD COLUMN IF NOT EXISTS model TEXT NOT NULL DEFAULT 'claude-sonnet-4-5'"
        )
    asyncio.create_task(redis_relay())
    yield
    await close_pool()

app = FastAPI(lifespan=lifespan, title="Orchestra API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class ProjectCreate(BaseModel):
    name: str
    description: Optional[str] = None
    github_repo: Optional[str] = None

class OrderCreate(BaseModel):
    title: str
    description: str

@app.get("/api/projects")
async def list_projects():
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT p.*, COUNT(o.id) AS order_count
            FROM project p
            LEFT JOIN "order" o ON o.project_id = p.id
            GROUP BY p.id ORDER BY p.created_at DESC
        """)
        return [dict(r) for r in rows]

@app.post("/api/projects", status_code=201)
async def create_project(body: ProjectCreate):
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "INSERT INTO project (name, description, github_repo) VALUES ($1,$2,$3) RETURNING *",
            body.name, body.description, body.github_repo)
        return dict(row)

@app.get("/api/projects/{project_id}")
async def get_project(project_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)
        if not row:
            raise HTTPException(404, "Not found")
        orders = await conn.fetch(
            'SELECT * FROM "order" WHERE project_id=$1 ORDER BY created_at DESC', project_id)
        return {**dict(row), "orders": [dict(o) for o in orders]}

@app.post("/api/projects/{project_id}/orders", status_code=201)
async def create_order(project_id: str, body: OrderCreate, bg: BackgroundTasks):
    pool = await get_pool()
    async with pool.acquire() as conn:
        if not await conn.fetchrow("SELECT id FROM project WHERE id=$1", project_id):
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
        rows = await conn.fetch(
            "SELECT id, order_id, project_id, title, description, agent_type, model, status, result, github_pr_url, sort_order, created_at, updated_at FROM task WHERE order_id=$1 ORDER BY sort_order",
            order_id)
        return [dict(r) for r in rows]

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

@app.get("/api/projects/{project_id}/artifacts")
async def list_artifacts(project_id: str):
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, task_id, kind, path, created_at FROM artifact WHERE project_id=$1 ORDER BY created_at",
            project_id)
        return [dict(r) for r in rows]

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

@app.get("/health")
async def health():
    return {"status": "ok"}
