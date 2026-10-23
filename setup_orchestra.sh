#!/usr/bin/env bash
# Orchestra – AI-powered project orchestration platform
# bash 3.2 compatible · idempotent
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; RESET='\033[0m'

log()  { printf "${BLUE}[orchestra]${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}[✓]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
die()  { printf "${RED}[✗]${RESET} %s\n" "$*"; exit 1; }

# ── 0. Prerequisites ──────────────────────────────────────────
log "Checking prerequisites..."
# Homebrew may not be in PATH when running via `bash script.sh`
if ! command -v brew >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/brew ]; then        # Apple Silicon
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then          # Intel
    eval "$(/usr/local/bin/brew shellenv)"
  else
    die "Homebrew not found. Install at https://brew.sh"
  fi
fi

if ! command -v python3.11 >/dev/null 2>&1 && ! command -v python3.12 >/dev/null 2>&1; then
  log "Installing Python 3.11..."
  brew install python@3.11
fi

PYTHON=$(command -v python3.12 2>/dev/null || command -v python3.11 2>/dev/null || die "Python 3.11+ required")
ok "Python: $($PYTHON --version)"

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop first."
ok "Docker is running"

# ── 1. Directory setup ────────────────────────────────────────
ROOT_DIR="$HOME/orchestra"
log "Setting up $ROOT_DIR..."

if [ -f "$ROOT_DIR/.env" ]; then
  cp "$ROOT_DIR/.env" /tmp/_orchestra_env_bak
fi

rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

if [ -f /tmp/_orchestra_env_bak ]; then
  cp /tmp/_orchestra_env_bak "$ROOT_DIR/.env"
  rm /tmp/_orchestra_env_bak
  ok ".env preserved"
fi

if [ ! -f "$ROOT_DIR/.env" ]; then
cat > "$ROOT_DIR/.env" <<'EOF'
ANTHROPIC_API_KEY=sk-ant-YOUR_KEY_HERE
EOF
  warn ".env created – fill in your ANTHROPIC_API_KEY before running Docker"
fi

mkdir -p orchestra/agents orchestra/api scripts web/src/components web/public

# ── 2. pyproject.toml ─────────────────────────────────────────
cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "orchestra"
version = "0.2.0"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.110",
    "uvicorn[standard]>=0.29",
    "asyncpg>=0.29",
    "redis>=5.0",
    "pydantic>=2.7",
    "python-dotenv>=1.0",
    "httpx>=0.27",
    "anthropic>=0.25",
    "structlog>=24.1",
]

[tool.setuptools.packages.find]
where = ["."]
include = ["orchestra*", "scripts*"]
EOF

# ── 3. schema.sql ─────────────────────────────────────────────
cat > schema.sql <<'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS project (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    description TEXT,
    status      TEXT NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS "order" (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id  UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS task (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id    UUID NOT NULL REFERENCES "order"(id) ON DELETE CASCADE,
    project_id  UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    description TEXT,
    agent_type  TEXT NOT NULL DEFAULT 'developer',
    status      TEXT NOT NULL DEFAULT 'pending',
    result      TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS execution (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     UUID NOT NULL REFERENCES task(id) ON DELETE CASCADE,
    agent_type  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'running',
    input       JSONB,
    output      TEXT,
    cost_usd    DECIMAL(10,6),
    tokens_used INTEGER,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS artifact (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id  UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    task_id     UUID REFERENCES task(id) ON DELETE SET NULL,
    kind        TEXT NOT NULL DEFAULT 'code',
    path        TEXT NOT NULL,
    content     BYTEA,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
EOF

# ── 4. Python package files ───────────────────────────────────
touch orchestra/__init__.py orchestra/agents/__init__.py orchestra/api/__init__.py

cat > orchestra/db.py <<'EOF'
import asyncpg, os

_pool = None

async def get_pool():
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=2, max_size=10)
    return _pool

async def close_pool():
    global _pool
    if _pool:
        await _pool.close()
        _pool = None
EOF

cat > orchestra/broadcast.py <<'EOF'
import redis.asyncio as aioredis
import json, os, logging

_redis = None
logger = logging.getLogger(__name__)

async def get_redis():
    global _redis
    if _redis is None:
        _redis = aioredis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379"))
    return _redis

async def broadcast(project_id: str, event: dict):
    try:
        r = await get_redis()
        await r.publish(f"project:{project_id}", json.dumps(event, default=str))
    except Exception as e:
        logger.error(f"broadcast error: {e}")
EOF

cat > orchestra/ws.py <<'EOF'
import logging
from typing import Dict, List
from fastapi import WebSocket

logger = logging.getLogger(__name__)

class ConnectionManager:
    def __init__(self):
        self.active: Dict[str, List[WebSocket]] = {}

    async def connect(self, ws: WebSocket, project_id: str):
        await ws.accept()
        self.active.setdefault(project_id, [])
        self.active[project_id].append(ws)

    def disconnect(self, ws: WebSocket, project_id: str):
        if project_id in self.active:
            try:
                self.active[project_id].remove(ws)
            except ValueError:
                pass

    async def broadcast_json(self, project_id: str, data: dict):
        dead = []
        for ws in self.active.get(project_id, []):
            try:
                await ws.send_json(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws, project_id)

manager = ConnectionManager()
EOF

# ── 5. Coordinator agent ──────────────────────────────────────
cat > orchestra/agents/coordinator.py <<'EOF'
import anthropic, json, os, uuid, logging, re
from orchestra.db import get_pool
from orchestra.broadcast import broadcast

logger = logging.getLogger(__name__)

async def process_order(order_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', order_id)
        if not order:
            return
        project_id = str(order['project_id'])

        await conn.execute(
            'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
            'analyzing', order_id)
        await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "analyzing"})

        client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

        prompt = f"""You are a software project coordinator. Break this order into 3-5 specific, actionable development tasks.

Order: {order['title']}
Description: {order['description']}

Return ONLY a JSON array (no markdown, no explanation):
[{{"title": "...", "description": "detailed description of what to implement", "agent_type": "developer"}}]"""

        try:
            msg = client.messages.create(
                model="claude-opus-4-5", max_tokens=2048,
                messages=[{"role": "user", "content": prompt}])
            text = msg.content[0].text.strip()
            text = re.sub(r'^```[a-z]*\n?', '', text)
            text = re.sub(r'\n?```$', '', text)
            tasks = json.loads(text)
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
            await conn.execute("""
                INSERT INTO task (id, order_id, project_id, title, description, agent_type, status, sort_order)
                VALUES ($1,$2,$3,$4,$5,$6,'pending',$7)
            """, task_id, order_id, project_id,
                t.get('title', 'Task'), t.get('description', ''), t.get('agent_type', 'developer'), i)

            await broadcast(project_id, {
                "type": "task_created",
                "task": {"id": task_id, "order_id": order_id, "title": t.get('title'),
                         "description": t.get('description'), "status": "pending", "sort_order": i}
            })
            task_ids.append(task_id)

        await conn.execute(
            'UPDATE "order" SET status=$1, updated_at=NOW() WHERE id=$2',
            'executing', order_id)
        await broadcast(project_id, {"type": "order_updated", "order_id": order_id, "status": "executing"})

    from orchestra.agents.developer import execute_task
    for task_id in task_ids:
        await execute_task(task_id, project_id)
EOF

# ── 6. Developer agent ────────────────────────────────────────
cat > orchestra/agents/developer.py <<'EOF'
import anthropic, json, os, re, uuid, logging
from orchestra.db import get_pool
from orchestra.broadcast import broadcast

logger = logging.getLogger(__name__)

def _parse_files(text: str):
    files = []
    pattern = r'###\s+`([^`\n]+)`\s*\n```(?:\w+)?\n(.*?)```'
    for path, content in re.findall(pattern, text, re.DOTALL):
        files.append({"path": path.strip(), "content": content.strip()})
    if not files:
        blocks = re.findall(r'```(?:python|javascript|typescript|sql|sh|bash|yaml|json|go|rust)?\n(.*?)```', text, re.DOTALL)
        for i, c in enumerate(blocks):
            ext = "py"
            if any(kw in c for kw in ["import React", "const ", "useState", "export default"]):
                ext = "jsx"
            elif "SELECT " in c or "CREATE TABLE" in c:
                ext = "sql"
            files.append({"path": f"generated/file_{i+1}.{ext}", "content": c.strip()})
    return files

async def execute_task(task_id: str, project_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT * FROM task WHERE id=$1", task_id)
        if not task:
            return
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', task['order_id'])

        await conn.execute("UPDATE task SET status='executing', updated_at=NOW() WHERE id=$1", task_id)
        await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "executing"})

        exec_id = str(uuid.uuid4())
        await conn.execute("""
            INSERT INTO execution (id, task_id, agent_type, status, input)
            VALUES ($1,$2,$3,'running',$4)
        """, exec_id, task_id, 'developer',
            json.dumps({"title": task['title'], "description": task['description']}))

        client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
        context = order['title'] if order else "Software project"
        prompt = f"""You are an expert software developer. Implement this task completely.

Project: {context}
Task: {task['title']}
Details: {task['description']}

For each file, use this exact format:
### `path/to/filename.ext`
```language
<file contents here>
```

Generate complete, working, production-quality code with error handling."""

        try:
            msg = client.messages.create(
                model="claude-opus-4-5", max_tokens=4096,
                messages=[{"role": "user", "content": prompt}])
            response_text = msg.content[0].text
            tokens_in = msg.usage.input_tokens
            tokens_out = msg.usage.output_tokens
            cost = (tokens_in * 0.015 + tokens_out * 0.075) / 1000
        except Exception as e:
            logger.error(f"Developer failed task={task_id}: {e}")
            await conn.execute("UPDATE task SET status='failed', updated_at=NOW() WHERE id=$1", task_id)
            await conn.execute("UPDATE execution SET status='failed', finished_at=NOW() WHERE id=$1", exec_id)
            await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "failed"})
            return

        files = _parse_files(response_text)
        artifact_ids = []
        for f in files:
            art_id = str(uuid.uuid4())
            await conn.execute("""
                INSERT INTO artifact (id, project_id, task_id, kind, path, content)
                VALUES ($1,$2,$3,'code',$4,$5)
            """, art_id, project_id, task_id, f['path'], f['content'].encode())
            artifact_ids.append({"id": art_id, "path": f['path']})

        await conn.execute("""
            UPDATE execution SET status='completed', output=$1, cost_usd=$2, tokens_used=$3, finished_at=NOW()
            WHERE id=$4
        """, response_text[:8000], cost, tokens_in + tokens_out, exec_id)

        result = json.dumps({"artifacts": artifact_ids, "files": len(files)})
        await conn.execute("UPDATE task SET status='completed', result=$1, updated_at=NOW() WHERE id=$2",
                           result, task_id)
        await broadcast(project_id, {
            "type": "task_updated", "task_id": task_id,
            "status": "completed", "artifacts": artifact_ids
        })

    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT order_id FROM task WHERE id=$1", task_id)
        if not task:
            return
        remaining = await conn.fetchval("""
            SELECT COUNT(*) FROM task
            WHERE order_id=$1 AND status NOT IN ('completed','failed')
        """, task['order_id'])
        if remaining == 0:
            await conn.execute(
                'UPDATE "order" SET status=\'completed\', updated_at=NOW() WHERE id=$1',
                task['order_id'])
            await broadcast(project_id, {
                "type": "order_updated",
                "order_id": str(task['order_id']),
                "status": "completed"
            })
EOF

# ── 7. FastAPI main ───────────────────────────────────────────
cat > orchestra/api/main.py <<'EOF'
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
    await get_pool()
    asyncio.create_task(redis_relay())
    yield
    await close_pool()

app = FastAPI(lifespan=lifespan, title="Orchestra API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class ProjectCreate(BaseModel):
    name: str
    description: Optional[str] = None

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
            "INSERT INTO project (name, description) VALUES ($1,$2) RETURNING *",
            body.name, body.description)
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
        rows = await conn.fetch("SELECT * FROM task WHERE order_id=$1 ORDER BY sort_order", order_id)
        return [dict(r) for r in rows]

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
EOF

# ── 8. Frontend ───────────────────────────────────────────────
cat > web/package.json <<'EOF'
{
  "name": "orchestra-web",
  "private": true,
  "version": "0.2.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.1",
    "vite": "^5.4.0"
  }
}
EOF

cat > web/vite.config.js <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': { target: 'http://localhost:8080', changeOrigin: true },
      '/ws':  { target: 'ws://localhost:8080', ws: true }
    }
  }
})
EOF

cat > web/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Orchestra</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat > web/src/main.jsx <<'EOF'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'
import './App.css'

createRoot(document.getElementById('root')).render(
  <StrictMode><App /></StrictMode>
)
EOF

cat > web/src/App.jsx <<'EOF'
import { useState, useEffect, useRef, useCallback } from 'react'

const AV_PALETTE = ['#34c759','#ff9500','#ff2d55','#007aff','#5856d6','#ff3b30','#af52de','#30b0c7','#ff6b35']

function avatarColor(str = '') {
  let h = 0
  for (let i = 0; i < str.length; i++) h = str.charCodeAt(i) + ((h << 5) - h)
  return AV_PALETTE[Math.abs(h) % AV_PALETTE.length]
}

function initials(str = '') {
  return str.split(' ').slice(0, 2).map(w => w[0] || '').join('').toUpperCase() || '?'
}

function Avatar({ name, size = 44 }) {
  const bg = avatarColor(name)
  return (
    <div className="avatar" style={{ '--av-bg': bg, '--av-size': size + 'px' }}>
      {initials(name)}
    </div>
  )
}

const STATUS_META = {
  pending:   { label: 'Pending',   bg: '#f1f1f4', fg: '#6b7280' },
  analyzing: { label: 'Analyzing', bg: '#fef3c7', fg: '#d97706' },
  executing: { label: 'Executing', bg: '#dbeafe', fg: '#2563eb' },
  completed: { label: 'Done',      bg: '#d1fae5', fg: '#059669' },
  failed:    { label: 'Failed',    bg: '#fee2e2', fg: '#dc2626' },
  blocked:   { label: 'Blocked',   bg: '#ffedd5', fg: '#ea580c' },
}

function Pill({ status }) {
  const m = STATUS_META[status] || STATUS_META.pending
  return (
    <span className="pill" style={{ '--p-bg': m.bg, '--p-fg': m.fg }}>
      {m.label}
    </span>
  )
}

function ArtifactModal({ artifact, onClose }) {
  const [content, setContent] = useState('Loading...')
  useEffect(() => {
    fetch(`/api/artifacts/${artifact.id}/content`)
      .then(r => r.text())
      .then(setContent)
      .catch(() => setContent('Failed to load'))
  }, [artifact.id])

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-header">
          <span className="modal-title">{artifact.path}</span>
          <button className="btn-icon" onClick={onClose}>✕</button>
        </div>
        <pre className="code-block">{content}</pre>
      </div>
    </div>
  )
}

function TaskRow({ task }) {
  const statusColor = task.status === 'completed' ? '#059669' : task.status === 'executing' ? '#2563eb' : task.status === 'failed' ? '#dc2626' : '#9ca3af'
  const icon = task.status === 'completed' ? '✓' : task.status === 'executing' ? '◌' : task.status === 'failed' ? '✗' : '○'
  return (
    <div className="task-row">
      <div className="task-icon-wrap" style={{ color: statusColor }}>{icon}</div>
      <div className="task-body">
        <div className="task-title">{task.title}</div>
        {task.description && <div className="task-desc">{task.description}</div>}
      </div>
      <Pill status={task.status} />
    </div>
  )
}

function OrderCard({ order, tasks, expanded, onExpand }) {
  const taskList = tasks[order.id] || []
  const done = taskList.filter(t => t.status === 'completed').length
  const agentName = 'Coordinator'
  const preview = order.description ? order.description.slice(0, 80) + (order.description.length > 80 ? '...' : '') : ''
  const ts = new Date(order.created_at)
  const timeStr = isNaN(ts) ? '' : ts.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

  return (
    <div className={`order-card${expanded ? ' expanded' : ''}`}>
      <div className="order-header" onClick={onExpand}>
        <Avatar name={agentName} size={42} />
        <div className="order-header-body">
          <div className="order-header-top">
            <span className="order-agent-name">{agentName}</span>
            <span className="order-time">{timeStr}</span>
          </div>
          <div className="order-title">{order.title}</div>
          {!expanded && preview && <div className="order-preview">{preview}</div>}
          <div className="order-header-foot">
            {taskList.length > 0 && <span className="order-task-count">{done}/{taskList.length} tasks</span>}
            <Pill status={order.status} />
          </div>
        </div>
      </div>
      {expanded && (
        <div className="order-body">
          <p className="order-desc">{order.description}</p>
          {taskList.length === 0 && order.status === 'pending' && (
            <p className="order-waiting">Waiting for coordinator...</p>
          )}
          {taskList.map(t => <TaskRow key={t.id} task={t} />)}
        </div>
      )}
    </div>
  )
}

export default function App() {
  const [page, setPage] = useState('home')
  const [projects, setProjects] = useState([])
  const [project, setProject] = useState(null)
  const [orders, setOrders] = useState([])
  const [tasks, setTasks] = useState({})
  const [artifacts, setArtifacts] = useState([])
  const [expandedOrders, setExpandedOrders] = useState({})
  const [selectedArtifact, setSelectedArtifact] = useState(null)
  const [showNewProject, setShowNewProject] = useState(false)
  const [showNewOrder, setShowNewOrder] = useState(false)
  const [newProjectName, setNewProjectName] = useState('')
  const [newProjectDesc, setNewProjectDesc] = useState('')
  const [newOrderTitle, setNewOrderTitle] = useState('')
  const [newOrderDesc, setNewOrderDesc] = useState('')
  const wsRef = useRef(null)

  const loadProjects = useCallback(async () => {
    const res = await fetch('/api/projects')
    setProjects(await res.json())
  }, [])

  useEffect(() => { loadProjects() }, [loadProjects])

  const openProject = async (p) => {
    setProject(p); setPage('project')
    setOrders([]); setTasks({}); setArtifacts({}); setExpandedOrders({})
    const res = await fetch(`/api/projects/${p.id}`)
    const data = await res.json()
    setOrders(data.orders || [])
    for (const o of data.orders || []) {
      const tr = await fetch(`/api/orders/${o.id}/tasks`)
      const td = await tr.json()
      setTasks(prev => ({ ...prev, [o.id]: td }))
    }
    const ar = await fetch(`/api/projects/${p.id}/artifacts`)
    setArtifacts(await ar.json())
    connectWs(p.id)
  }

  const connectWs = (projectId) => {
    if (wsRef.current) wsRef.current.close()
    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const ws = new WebSocket(`${proto}://${window.location.host}/ws/${projectId}`)
    ws.onmessage = (e) => {
      const ev = JSON.parse(e.data)
      if (ev.type === 'order_updated') {
        setOrders(prev => prev.map(o => o.id === ev.order_id ? { ...o, status: ev.status } : o))
        if (ev.status === 'completed') {
          fetch(`/api/projects/${projectId}/artifacts`).then(r => r.json()).then(setArtifacts)
        }
      } else if (ev.type === 'task_created') {
        setTasks(prev => ({
          ...prev,
          [ev.task.order_id]: [...(prev[ev.task.order_id] || []), ev.task]
        }))
        setExpandedOrders(prev => ({ ...prev, [ev.task.order_id]: true }))
      } else if (ev.type === 'task_updated') {
        setTasks(prev => {
          const next = {}
          for (const [k, v] of Object.entries(prev)) {
            next[k] = v.map(t => t.id === ev.task_id ? { ...t, status: ev.status } : t)
          }
          return next
        })
      }
    }
    wsRef.current = ws
  }

  const createProject = async () => {
    if (!newProjectName.trim()) return
    const res = await fetch('/api/projects', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: newProjectName, description: newProjectDesc })
    })
    const p = await res.json()
    setProjects(prev => [p, ...prev])
    setNewProjectName(''); setNewProjectDesc(''); setShowNewProject(false)
  }

  const createOrder = async () => {
    if (!newOrderTitle.trim() || !project) return
    const res = await fetch(`/api/projects/${project.id}/orders`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: newOrderTitle, description: newOrderDesc })
    })
    const o = await res.json()
    setOrders(prev => [o, ...prev])
    setTasks(prev => ({ ...prev, [o.id]: [] }))
    setExpandedOrders(prev => ({ ...prev, [o.id]: true }))
    setNewOrderTitle(''); setNewOrderDesc(''); setShowNewOrder(false)
  }

  if (page === 'home') return (
    <div className="app">
      <header className="top-bar">
        <div className="logo">Orchestra</div>
        <button className="btn-primary" onClick={() => setShowNewProject(true)}>+ New Project</button>
      </header>

      {showNewProject && (
        <div className="modal-overlay" onClick={() => setShowNewProject(false)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">New Project</span>
              <button className="btn-icon" onClick={() => setShowNewProject(false)}>✕</button>
            </div>
            <div className="form-body">
              <input className="input" placeholder="Project name" value={newProjectName}
                onChange={e => setNewProjectName(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && createProject()} autoFocus />
              <textarea className="input" placeholder="Description (optional)" rows={3}
                value={newProjectDesc} onChange={e => setNewProjectDesc(e.target.value)} />
              <button className="btn-primary" onClick={createProject}>Create Project</button>
            </div>
          </div>
        </div>
      )}

      <main className="main-content">
        {projects.length === 0 ? (
          <div className="empty-state">
            <div className="empty-icon">◎</div>
            <h2>No projects yet</h2>
            <p>Create a project and give autonomous AI agents their orders.</p>
            <button className="btn-primary" onClick={() => setShowNewProject(true)}>Create your first project</button>
          </div>
        ) : (
          <div className="project-grid">
            {projects.map(p => (
              <div key={p.id} className="project-card" onClick={() => openProject(p)}>
                <Avatar name={p.name} size={48} />
                <div className="project-card-body">
                  <div className="project-card-name">{p.name}</div>
                  {p.description && <div className="project-card-desc">{p.description}</div>}
                  <div className="project-card-meta">{p.order_count || 0} orders</div>
                </div>
              </div>
            ))}
          </div>
        )}
      </main>
    </div>
  )

  return (
    <div className="app">
      <header className="top-bar">
        <button className="btn-ghost" onClick={() => {
          setPage('home'); loadProjects();
          if (wsRef.current) wsRef.current.close()
        }}>← Projects</button>
        <div className="logo">{project?.name}</div>
        <button className="btn-primary" onClick={() => setShowNewOrder(true)}>+ New Order</button>
      </header>

      {showNewOrder && (
        <div className="modal-overlay" onClick={() => setShowNewOrder(false)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">New Order</span>
              <button className="btn-icon" onClick={() => setShowNewOrder(false)}>✕</button>
            </div>
            <div className="form-body">
              <input className="input" placeholder="What do you want to build?" value={newOrderTitle}
                onChange={e => setNewOrderTitle(e.target.value)} autoFocus />
              <textarea className="input" placeholder="Describe in detail what the agents should implement..." rows={5}
                value={newOrderDesc} onChange={e => setNewOrderDesc(e.target.value)} />
              <button className="btn-primary" onClick={createOrder}>Send to Coordinator</button>
            </div>
          </div>
        </div>
      )}

      {selectedArtifact && (
        <ArtifactModal artifact={selectedArtifact} onClose={() => setSelectedArtifact(null)} />
      )}

      <main className="main-content two-col">
        <section className="orders-section">
          {orders.length === 0 ? (
            <div className="empty-state small">
              <p>No orders yet. Tell the agents what to build.</p>
            </div>
          ) : orders.map(o => (
            <OrderCard key={o.id} order={o} tasks={tasks}
              expanded={!!expandedOrders[o.id]}
              onExpand={() => setExpandedOrders(prev => ({ ...prev, [o.id]: !prev[o.id] }))} />
          ))}
        </section>

        {artifacts.length > 0 && (
          <aside className="artifacts-panel">
            <div className="panel-title">Generated Files</div>
            {artifacts.map(a => (
              <div key={a.id} className="artifact-row" onClick={() => setSelectedArtifact(a)}>
                <span className="artifact-icon">📄</span>
                <span className="artifact-path">{a.path}</span>
              </div>
            ))}
          </aside>
        )}
      </main>
    </div>
  )
}
EOF

cat > web/src/App.css <<'EOF'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');

:root {
  --bg: #f2f2f7;
  --surface: #ffffff;
  --surface2: #f9f9fb;
  --border: rgba(0,0,0,.08);
  --fg: #1c1c1e;
  --fg2: #6e6e73;
  --accent: #5856d6;
  --accent-h: #4340c4;
  --radius: 14px;
  --shadow: 0 1px 3px rgba(0,0,0,.07), 0 4px 12px rgba(0,0,0,.05);
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
  color-scheme: light;
}


*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--fg); min-height: 100vh; }
.app { display: flex; flex-direction: column; min-height: 100vh; }

.top-bar {
  display: flex; align-items: center; justify-content: space-between;
  padding: 0 max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
  height: 60px; background: var(--surface); border-bottom: 1px solid var(--border);
  position: sticky; top: 0; z-index: 10;
}
.logo { font-weight: 700; font-size: 1.05rem; letter-spacing: -0.02em; color: var(--fg); }

.main-content {
  flex: 1; padding: 20px max(16px, env(safe-area-inset-left, 0px));
  padding-right: max(16px, env(safe-area-inset-right, 0px));
  max-width: 1100px; margin: 0 auto; width: 100%;
}
.two-col { display: grid; grid-template-columns: 1fr 260px; gap: 20px; align-items: start; }
@media (max-width: 700px) { .two-col { grid-template-columns: 1fr; } }

.btn-primary {
  background: var(--accent); color: #fff; border: none;
  padding: 8px 18px; border-radius: 10px; font-size: 0.875rem; font-weight: 600;
  cursor: pointer; transition: background .15s, transform .1s; font-family: inherit;
}
.btn-primary:hover { background: var(--accent-h); transform: translateY(-1px); }
.btn-primary:active { transform: translateY(0); }
.btn-ghost {
  background: transparent; color: var(--fg2); border: none;
  padding: 8px 12px; border-radius: 10px; font-size: 0.875rem; cursor: pointer; font-family: inherit;
}
.btn-ghost:hover { background: var(--surface2); color: var(--fg); }
.btn-icon { background: none; border: none; color: var(--fg2); cursor: pointer; font-size: 1.1rem; padding: 4px 8px; border-radius: 6px; }
.btn-icon:hover { background: var(--surface2); color: var(--fg); }

.avatar {
  width: var(--av-size); height: var(--av-size); border-radius: 12px;
  background: var(--av-bg); color: #fff;
  display: flex; align-items: center; justify-content: center;
  font-weight: 700; font-size: calc(var(--av-size) * 0.36);
  flex-shrink: 0; letter-spacing: -0.03em;
}

.pill {
  display: inline-flex; align-items: center;
  padding: 2px 9px; border-radius: 20px;
  background: var(--p-bg); color: var(--p-fg);
  font-size: 0.6875rem; font-weight: 600; white-space: nowrap;
}

.modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,.35); display: flex; align-items: center; justify-content: center; z-index: 100; backdrop-filter: blur(4px); }
.modal { background: var(--surface); border-radius: 18px; width: 540px; max-width: 95vw; max-height: 90vh; overflow-y: auto; box-shadow: 0 20px 60px rgba(0,0,0,.18); }
.modal-header { display: flex; align-items: center; justify-content: space-between; padding: 18px 20px; border-bottom: 1px solid var(--border); }
.modal-title { font-weight: 600; font-size: 1rem; }
.form-body { display: flex; flex-direction: column; gap: 12px; padding: 20px; }

.input {
  background: var(--surface2); border: 1.5px solid var(--border); color: var(--fg);
  padding: 10px 14px; border-radius: 10px; font-size: 0.875rem; width: 100%; resize: vertical; font-family: inherit;
  transition: border-color .15s;
}
.input:focus { outline: none; border-color: var(--accent); }
.input::placeholder { color: var(--fg2); }

.empty-state { text-align: center; padding: 80px 24px; color: var(--fg2); }
.empty-state.small { padding: 32px 24px; }
.empty-icon { font-size: 2.5rem; margin-bottom: 16px; }
.empty-state h2 { font-size: 1.2rem; margin-bottom: 8px; color: var(--fg); font-weight: 600; }
.empty-state p { margin-bottom: 24px; line-height: 1.6; }

.project-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 14px; }
.project-card {
  background: var(--surface); border-radius: var(--radius); padding: 18px; cursor: pointer;
  display: flex; gap: 14px; align-items: flex-start;
  box-shadow: var(--shadow); transition: transform .15s, box-shadow .15s;
}
.project-card:hover { transform: translateY(-2px); box-shadow: 0 4px 16px rgba(0,0,0,.1); }
.project-card-body { flex: 1; min-width: 0; }
.project-card-name { font-weight: 600; margin-bottom: 4px; }
.project-card-desc { font-size: 0.8125rem; color: var(--fg2); margin-bottom: 8px; line-height: 1.5; }
.project-card-meta { font-size: 0.75rem; color: var(--fg2); }

.orders-section { display: flex; flex-direction: column; gap: 10px; }
.order-card { background: var(--surface); border-radius: var(--radius); overflow: hidden; box-shadow: var(--shadow); }
.order-header { padding: 14px 16px; cursor: pointer; user-select: none; display: flex; gap: 12px; align-items: flex-start; transition: background .1s; }
.order-header:hover { background: var(--surface2); }
.order-header-body { flex: 1; min-width: 0; }
.order-header-top { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 3px; }
.order-agent-name { font-weight: 600; font-size: 0.9rem; color: var(--fg); }
.order-time { font-size: 0.7rem; color: var(--fg2); flex-shrink: 0; margin-left: 8px; }
.order-title { font-size: 0.875rem; color: var(--fg); margin-bottom: 3px; line-height: 1.4; }
.order-preview { font-size: 0.8125rem; color: var(--fg2); line-height: 1.4; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-bottom: 6px; }
.order-header-foot { display: flex; align-items: center; gap: 8px; }
.order-task-count { font-size: 0.7rem; color: var(--fg2); }
.order-body { padding: 0 16px 14px 70px; border-top: 1px solid var(--border); }
.order-desc { font-size: 0.8125rem; color: var(--fg2); padding: 10px 0; line-height: 1.6; }
.order-waiting { font-size: 0.8125rem; color: var(--fg2); padding: 8px 0; font-style: italic; }

.task-row { display: flex; align-items: flex-start; gap: 10px; padding: 7px 0; border-bottom: 1px solid var(--border); }
.task-row:last-child { border-bottom: none; }
.task-icon-wrap { flex-shrink: 0; width: 18px; text-align: center; font-size: 0.8rem; margin-top: 2px; }
.task-body { flex: 1; min-width: 0; }
.task-title { font-size: 0.8375rem; font-weight: 500; color: var(--fg); }
.task-desc { font-size: 0.75rem; color: var(--fg2); margin-top: 2px; line-height: 1.5; }

.artifacts-panel { background: var(--surface); border-radius: var(--radius); padding: 16px; position: sticky; top: 76px; box-shadow: var(--shadow); }
.panel-title { font-weight: 600; font-size: 0.6875rem; margin-bottom: 10px; color: var(--fg2); text-transform: uppercase; letter-spacing: .06em; }
.artifact-row { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 8px; cursor: pointer; font-size: 0.8125rem; transition: background .1s; }
.artifact-row:hover { background: var(--surface2); }
.artifact-icon { flex-shrink: 0; }
.artifact-path { color: var(--fg2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; min-width: 0; }
.artifact-row:hover .artifact-path { color: var(--fg); }

.code-block { margin: 0; padding: 20px; font-family: 'SF Mono', 'Fira Code', ui-monospace, monospace; font-size: 0.8125rem; color: var(--fg); background: var(--surface2); overflow-x: auto; white-space: pre; max-height: 70vh; overflow-y: auto; line-height: 1.6; }
EOF

# ── 9. Dockerfiles ────────────────────────────────────────────
cat > Dockerfile.api <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml .
RUN pip install --no-cache-dir -e . 2>&1 | tail -5 || pip install fastapi uvicorn[standard] asyncpg redis pydantic python-dotenv httpx anthropic structlog
COPY orchestra/ orchestra/
COPY scripts/ scripts/
COPY schema.sql .
EXPOSE 8080
CMD ["uvicorn", "orchestra.api.main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

cat > Dockerfile.web <<'EOF'
FROM node:20-alpine AS build
WORKDIR /app
COPY web/package.json .
RUN npm install
COPY web/ .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
EOF

cat > nginx.conf <<'EOF'
server {
    listen 80;

    location /api/ {
        proxy_pass         http://api:8080;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
    }

    location /ws/ {
        proxy_pass         http://api:8080;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_read_timeout 86400;
    }

    location / {
        root  /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
}
EOF

# ── 10. docker-compose.yml ────────────────────────────────────
cat > docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: orchestra
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 10

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

  api:
    build:
      context: .
      dockerfile: Dockerfile.api
    env_file: [.env]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres/orchestra
      REDIS_URL: redis://redis:6379
    ports: ["8080:8080"]
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  web:
    build:
      context: .
      dockerfile: Dockerfile.web
    ports: ["3000:80"]
    depends_on: [api]

volumes:
  pgdata:
EOF

# ── 11. Build and run ─────────────────────────────────────────
log "Creating Python virtualenv..."
$PYTHON -m venv .venv
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -e .
ok "Python environment ready"

log "Starting Docker stack (first build may take a few minutes)..."
docker compose down -v --remove-orphans 2>/dev/null || true
docker compose up -d --build

log "Waiting for Postgres..."
for i in $(seq 1 30); do
  if docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

log "Applying schema..."
docker compose exec -T api python -c "
import asyncio, asyncpg, pathlib, os
async def run():
    conn = await asyncpg.connect(os.environ['DATABASE_URL'])
    await conn.execute(pathlib.Path('schema.sql').read_text())
    await conn.close()
asyncio.run(run())
"

PROJECT_ID=$(docker compose exec -T api python -c "
import asyncio, asyncpg, os
async def run():
    conn = await asyncpg.connect(os.environ['DATABASE_URL'])
    r = await conn.fetchrow(\"INSERT INTO project (name,description) VALUES ('Demo','First Orchestra project') RETURNING id\")
    print(r['id'])
    await conn.close()
asyncio.run(run())
" 2>/dev/null | tr -d '\r' | tail -1)

printf "\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "${GREEN}  Orchestra is running!${RESET}\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  Dashboard  : ${BLUE}http://localhost:3000${RESET}\n"
printf "  API        : ${BLUE}http://localhost:8080${RESET}\n"
printf "  Project ID : ${YELLOW}%s${RESET}\n" "$PROJECT_ID"
printf "\n"
printf "  Try it via curl:\n"
printf "  ${YELLOW}curl -s -X POST http://localhost:8080/api/projects/$PROJECT_ID/orders\\\n"
printf "    -H 'Content-Type: application/json'\\\n"
printf "    -d '{\"title\":\"Build a todo REST API\",\"description\":\"CRUD endpoints for todos with PostgreSQL\"}'${RESET}\n"
printf "\n"
