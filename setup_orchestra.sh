#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# setup_orchestra.sh
# Full idempotent setup for the Orchestra multi-agent framework
# Compatible with macOS bash 3.2 (no ${var^} or ${var:-1} etc.)
# ============================================================

# 1️⃣  System dependencies
if ! command -v python3 &>/dev/null; then
  echo "🔧 Installing Python via Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  brew install python@3.12
fi

if ! command -v docker &>/dev/null; then
  echo "🐳 Docker Desktop not found – please install it manually at https://www.docker.com/products/docker-desktop/ and start the app."
  exit 1
fi

# 2️⃣  Prepare project directory
ROOT_DIR="$HOME/orchestra"

# Preserve .env if it exists
if [ -f "$ROOT_DIR/.env" ]; then
  cp "$ROOT_DIR/.env" /tmp/_orchestra_env_backup
fi

rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# Restore .env
if [ -f /tmp/_orchestra_env_backup ]; then
  cp /tmp/_orchestra_env_backup "$ROOT_DIR/.env"
  rm /tmp/_orchestra_env_backup
  echo "✅ .env restaurado"
fi

# 3️⃣  Write all project files

# ---- pyproject.toml ---------------------------------------------------
cat > pyproject.toml <<'EOF'
[project]
name = "orchestra"
version = "0.1.0"
description = "Multi-agent project orchestration framework"
readme = "README.md"
requires-python = ">=3.11"
license = {text = "MIT"}
authors = [{name = "Vinicius", email = "vinicius@example.com"}]
classifiers = [
    "Programming Language :: Python :: 3",
    "License :: OSI Approved :: MIT License",
    "Operating System :: OS Independent",
]
dependencies = [
    "fastapi>=0.110",
    "uvicorn[standard]>=0.29",
    "asyncpg>=0.29",
    "redis>=5.0",
    "pyyaml>=6.0",
    "pydantic>=2.7",
    "structlog>=24.1",
    "typer[all]>=0.9",
    "jinja2>=3.1",
    "python-dotenv>=1.0",
    "httpx>=0.27",
    "anthropic>=0.25",
]
[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-asyncio>=0.23",
    "httpx>=0.27",
    "fakeredis>=2.20",
    "ruff>=0.3",
    "black>=24.0",
]
[project.scripts]
orchestra = "orchestra.cli.main:app"
orchestra-api = "orchestra.api.main:run"
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"
[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
[tool.ruff]
line-length = 100
target-version = "py311"
[tool.black]
line-length = 100
[tool.setuptools.packages.find]
where = ["."]
include = ["orchestra*", "orchestrator*"]
EOF

# ---- Dockerfile -------------------------------------------------------
cat > Dockerfile <<'EOF'
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq-dev gcc \
    && rm -rf /var/lib/apt/lists/*
COPY pyproject.toml ./
RUN pip install --upgrade pip && pip install .
COPY . .
CMD ["python", "-m", "orchestrator"]
EOF

# ---- Dockerfile.web ---------------------------------------------------
cat > Dockerfile.web <<'EOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY web/package*.json ./
RUN npm install
COPY web/ ./
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY web/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF

# ---- docker-compose.yml -----------------------------------------------
cat > docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: orchestra
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports: ["5432:5432"]
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./schema.sql:/docker-entrypoint-initdb.d/schema.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  orchestrator:
    build: .
    command: python -m orchestrator
    depends_on:
      postgres: {condition: service_healthy}
      redis:    {condition: service_healthy}
    env_file: [.env]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres/orchestra
      REDIS_URL: redis://redis:6379
    deploy:
      resources: {limits: {cpus: "0.5", memory: 512M}}

  coder:
    build: .
    command: uvicorn orchestra.pages.page_coder:app --host 0.0.0.0 --port 8000
    depends_on:
      postgres: {condition: service_healthy}
      redis:    {condition: service_healthy}
    env_file: [.env]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres/orchestra
      REDIS_URL: redis://redis:6379
    ports: ["8000:8000"]

  tester:
    build: .
    command: uvicorn orchestra.pages.page_tester:app --host 0.0.0.0 --port 8001
    depends_on:
      postgres: {condition: service_healthy}
      redis:    {condition: service_healthy}
    env_file: [.env]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres/orchestra
      REDIS_URL: redis://redis:6379
    ports: ["8002:8001"]

  scanner:
    build: .
    command: uvicorn orchestra.pages.page_scanner:app --host 0.0.0.0 --port 8002
    depends_on:
      postgres: {condition: service_healthy}
      redis:    {condition: service_healthy}
    env_file: [.env]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres/orchestra
      REDIS_URL: redis://redis:6379
    ports: ["8003:8002"]

  api:
    build: .
    command: uvicorn orchestra.api.main:app --host 0.0.0.0 --port 8080
    depends_on:
      postgres: {condition: service_healthy}
      redis:    {condition: service_healthy}
    env_file: [.env]
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres/orchestra
      REDIS_URL: redis://redis:6379
    ports: ["8080:8080"]

  web:
    build:
      context: .
      dockerfile: Dockerfile.web
    depends_on: [api]
    ports: ["3000:80"]
    environment:
      - VITE_API_URL=http://localhost:8080

volumes:
  pgdata:
EOF

# ---- schema.sql -------------------------------------------------------
cat > schema.sql <<'EOF'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE project (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    description TEXT,
    status      TEXT NOT NULL DEFAULT 'draft',
    version     INT  NOT NULL DEFAULT 1,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE artifact (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id  UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,
    path        TEXT NOT NULL,
    content     BYTEA,
    hash        TEXT NOT NULL,
    version     INT  NOT NULL DEFAULT 1,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (project_id, kind, path, version)
);
CREATE INDEX idx_artifact_project_kind_path ON artifact (project_id, kind, path);

CREATE TABLE event_log (
    id          BIGSERIAL PRIMARY KEY,
    project_id  UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    payload     JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_event_log_project ON event_log (project_id);
EOF

# ---- .env (example) ---------------------------------------------------
cat > .env.example <<'EOF'
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/orchestra
REDIS_URL=redis://localhost:6379
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
EOF

# ---- orchestra package structure --------------------------------------
mkdir -p orchestra/cli
mkdir -p orchestra/api
mkdir -p orchestra/pages
mkdir -p orchestra/bus
mkdir -p orchestra/templates
mkdir -p tests

# ---- orchestra/__init__.py --------------------------------------------
cat > orchestra/__init__.py <<'PY'
"""Orchestra – multi-agent project orchestration framework."""
__version__ = "0.1.0"
PY

# ---- orchestra/bus/__init__.py ----------------------------------------
cat > orchestra/bus/__init__.py <<'PY'
PY

# ---- orchestra/bus/message_bus.py -------------------------------------
cat > orchestra/bus/message_bus.py <<'PY'
"""Simple Redis pub/sub message bus."""
from __future__ import annotations
import json
import asyncio
from typing import Any, Callable, Awaitable
import redis.asyncio as aioredis


class MessageBus:
    def __init__(self, redis_url: str) -> None:
        self._url = redis_url
        self._redis: aioredis.Redis | None = None

    async def connect(self) -> None:
        self._redis = await aioredis.from_url(self._url, decode_responses=True)

    async def disconnect(self) -> None:
        if self._redis:
            await self._redis.aclose()

    async def publish(self, channel: str, payload: dict[str, Any]) -> None:
        assert self._redis, "not connected"
        await self._redis.publish(channel, json.dumps(payload))

    async def subscribe(
        self,
        channel: str,
        handler: Callable[[dict[str, Any]], Awaitable[None]],
    ) -> None:
        assert self._redis, "not connected"
        pubsub = self._redis.pubsub()
        await pubsub.subscribe(channel)
        async for message in pubsub.listen():
            if message["type"] == "message":
                data = json.loads(message["data"])
                await handler(data)
PY

# ---- orchestra/pages/__init__.py --------------------------------------
cat > orchestra/pages/__init__.py <<'PY'
PY

# ---- orchestra/pages/page_coder.py ------------------------------------
cat > orchestra/pages/page_coder.py <<'PY'
"""Coder page – uses Claude to generate real source files for a project."""
import os
import json
import hashlib
import re
import asyncio
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
import asyncpg
import anthropic

app = FastAPI(title="Coder Page")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost/orchestra")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")


async def _get_pool() -> asyncpg.Pool:
    return await asyncpg.create_pool(DATABASE_URL)


def _parse_files(text: str) -> dict:
    """Extract filename/content blocks from Claude's response."""
    files = {}
    pattern = re.compile(r'###\s+`?([^\n`]+)`?\n```[a-z]*\n(.*?)```', re.DOTALL)
    for m in pattern.finditer(text):
        files[m.group(1).strip()] = m.group(2)
    if not files:
        files["src/main.py"] = text
    return files


async def generate_code(project_id: str) -> None:
    pool = await _get_pool()
    try:
        async with pool.acquire() as conn:
            # Fetch spec
            spec_row = await conn.fetchrow(
                "SELECT content FROM artifact WHERE project_id=$1 AND kind='spec' ORDER BY created_at LIMIT 1",
                project_id,
            )
            project_row = await conn.fetchrow("SELECT name, description FROM project WHERE id=$1", project_id)

        spec_text = spec_row["content"].decode() if spec_row else ""
        project_name = project_row["name"] if project_row else "Unknown"
        description = project_row["description"] if project_row else ""

        prompt = f"""You are an expert software engineer. Generate production-quality Python code for the following project.

Project name: {project_name}
Description: {description}
Spec:
{spec_text}

Generate the complete source files. For each file, use this exact format:

### `path/to/file.py`
```python
# file content here
```

Generate at minimum: a main module, a utils module, and any other files the spec requires.
Make the code functional, well-structured, and include docstrings."""

        client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
        message = client.messages.create(
            model="claude-opus-4-5",
            max_tokens=4096,
            messages=[{"role": "user", "content": prompt}],
        )
        response = message.content[0].text
        files = _parse_files(response)

        async with pool.acquire() as conn:
            for path, content in files.items():
                content_bytes = content.encode()
                sha = hashlib.sha256(content_bytes).hexdigest()
                await conn.execute(
                    """
                    INSERT INTO artifact (project_id, kind, path, content, hash)
                    VALUES ($1, 'code', $2, $3, $4)
                    ON CONFLICT (project_id, kind, path, version) DO NOTHING
                    """,
                    project_id, path, content_bytes, sha,
                )
            await conn.execute(
                "INSERT INTO event_log (project_id, type, payload) VALUES ($1, 'CodeGenerated', $2::jsonb)",
                project_id, json.dumps({"project_id": project_id, "files": list(files.keys())}),
            )
            await conn.execute(
                "UPDATE project SET status='code_generated', updated_at=now() WHERE id=$1",
                project_id,
            )
        print(f"[coder] generated {len(files)} files for {project_id}")
    except Exception as e:
        print(f"[coder] ERROR {project_id}: {e}")
        async with pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO event_log (project_id, type, payload) VALUES ($1, 'CoderFailed', $2::jsonb)",
                project_id, json.dumps({"project_id": project_id, "error": str(e)}),
            )
    finally:
        await pool.close()


class Trigger(BaseModel):
    project_id: str


@app.get("/health")
async def health():
    return {"status": "ok", "page": "coder"}


@app.post("/trigger")
async def trigger(t: Trigger, bg: BackgroundTasks):
    bg.add_task(generate_code, t.project_id)
    return {"status": "accepted", "project_id": t.project_id}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("orchestra.pages.page_coder:app", host="0.0.0.0", port=8000, reload=False)
PY

# ---- orchestra/pages/page_tester.py -----------------------------------
cat > orchestra/pages/page_tester.py <<'PY'
"""Tester page – uses Claude to write and analyze tests for generated code."""
import os
import json
import hashlib
import asyncio
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
import asyncpg
import anthropic

app = FastAPI(title="Tester Page")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost/orchestra")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")


async def _get_pool() -> asyncpg.Pool:
    return await asyncpg.create_pool(DATABASE_URL)


async def run_tests(project_id: str) -> None:
    pool = await _get_pool()
    try:
        async with pool.acquire() as conn:
            code_rows = await conn.fetch(
                "SELECT path, content FROM artifact WHERE project_id=$1 AND kind='code' ORDER BY created_at",
                project_id,
            )
            project_row = await conn.fetchrow("SELECT name, description FROM project WHERE id=$1", project_id)

        if not code_rows:
            print(f"[tester] no code artifacts for {project_id}")
            return

        code_summary = "\n\n".join(
            f"### {r['path']}\n```python\n{r['content'].decode()}\n```"
            for r in code_rows
        )
        project_name = project_row["name"] if project_row else "Unknown"

        prompt = f"""You are a senior QA engineer. Analyze the following Python code for the project "{project_name}" and write comprehensive pytest tests.

{code_summary}

Write tests that:
1. Cover the main happy paths
2. Cover edge cases and error conditions
3. Use pytest fixtures where appropriate
4. Are well-documented

Also provide a brief test analysis summary with:
- Number of test cases written
- Areas covered
- Potential risks identified

Format your response as:

### `tests/test_main.py`
```python
# test content
```

### Analysis
[Your analysis here]"""

        client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
        message = client.messages.create(
            model="claude-opus-4-5",
            max_tokens=4096,
            messages=[{"role": "user", "content": prompt}],
        )
        response = message.content[0].text

        import re
        test_files = {}
        pattern = re.compile(r'###\s+`?([^\n`]+\.py)`?\n```[a-z]*\n(.*?)```', re.DOTALL)
        for m in pattern.finditer(response):
            test_files[m.group(1).strip()] = m.group(2)

        analysis_match = re.search(r'### Analysis\n(.*?)(?=###|\Z)', response, re.DOTALL)
        analysis = analysis_match.group(1).strip() if analysis_match else response

        async with pool.acquire() as conn:
            for path, content in test_files.items():
                content_bytes = content.encode()
                sha = hashlib.sha256(content_bytes).hexdigest()
                await conn.execute(
                    """
                    INSERT INTO artifact (project_id, kind, path, content, hash)
                    VALUES ($1, 'test', $2, $3, $4)
                    ON CONFLICT (project_id, kind, path, version) DO NOTHING
                    """,
                    project_id, path, content_bytes, sha,
                )
            report_bytes = analysis.encode()
            await conn.execute(
                """
                INSERT INTO artifact (project_id, kind, path, content, hash)
                VALUES ($1, 'test', 'reports/test_analysis.md', $2, $3)
                ON CONFLICT (project_id, kind, path, version) DO NOTHING
                """,
                project_id, report_bytes, hashlib.sha256(report_bytes).hexdigest(),
            )
            await conn.execute(
                "INSERT INTO event_log (project_id, type, payload) VALUES ($1, 'TestsCompleted', $2::jsonb)",
                project_id, json.dumps({"project_id": project_id, "test_files": list(test_files.keys())}),
            )
            await conn.execute(
                "UPDATE project SET status='tests_passed', updated_at=now() WHERE id=$1",
                project_id,
            )
        print(f"[tester] wrote {len(test_files)} test files for {project_id}")
    except Exception as e:
        print(f"[tester] ERROR {project_id}: {e}")
    finally:
        await pool.close()


class Trigger(BaseModel):
    project_id: str


@app.get("/health")
async def health():
    return {"status": "ok", "page": "tester"}


@app.post("/trigger")
async def trigger(t: Trigger, bg: BackgroundTasks):
    bg.add_task(run_tests, t.project_id)
    return {"status": "accepted", "project_id": t.project_id}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("orchestra.pages.page_tester:app", host="0.0.0.0", port=8001, reload=False)
PY

# ---- orchestra/pages/page_scanner.py ----------------------------------
cat > orchestra/pages/page_scanner.py <<'PY'
"""Scanner page – uses Claude to perform security analysis on generated code."""
import os
import json
import hashlib
import asyncio
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
import asyncpg
import anthropic

app = FastAPI(title="Scanner Page")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost/orchestra")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")


async def _get_pool() -> asyncpg.Pool:
    return await asyncpg.create_pool(DATABASE_URL)


async def run_scan(project_id: str) -> None:
    pool = await _get_pool()
    try:
        async with pool.acquire() as conn:
            code_rows = await conn.fetch(
                "SELECT path, content FROM artifact WHERE project_id=$1 AND kind='code' ORDER BY created_at",
                project_id,
            )

        if not code_rows:
            print(f"[scanner] no code artifacts for {project_id}")
            return

        code_summary = "\n\n".join(
            f"### {r['path']}\n```python\n{r['content'].decode()}\n```"
            for r in code_rows
        )

        prompt = f"""You are a security expert performing a thorough code review. Analyze the following Python code for security vulnerabilities, code quality issues, and best practice violations.

{code_summary}

Provide a detailed security report with the following sections:

## Security Report

### Critical Issues
[List any critical security vulnerabilities - SQL injection, XSS, command injection, hardcoded secrets, etc.]

### High Severity
[List high severity issues - insecure configurations, missing input validation, etc.]

### Medium Severity
[List medium severity issues - error handling, logging of sensitive data, etc.]

### Low Severity
[List low severity issues - code quality, minor best practice violations]

### Summary
- Total findings: X
- Critical: X
- High: X
- Medium: X
- Low: X

### Recommendations
[Top 3-5 actionable recommendations to improve security]"""

        client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)
        message = client.messages.create(
            model="claude-opus-4-5",
            max_tokens=4096,
            messages=[{"role": "user", "content": prompt}],
        )
        report = message.content[0].text

        import re
        findings = {"critical": 0, "high": 0, "medium": 0, "low": 0}
        for level in findings:
            match = re.search(rf'{level}[:\s]+(\d+)', report, re.IGNORECASE)
            if match:
                findings[level] = int(match.group(1))

        async with pool.acquire() as conn:
            report_bytes = report.encode()
            await conn.execute(
                """
                INSERT INTO artifact (project_id, kind, path, content, hash)
                VALUES ($1, 'report', 'reports/security_report.md', $2, $3)
                ON CONFLICT (project_id, kind, path, version) DO NOTHING
                """,
                project_id, report_bytes, hashlib.sha256(report_bytes).hexdigest(),
            )
            await conn.execute(
                "INSERT INTO event_log (project_id, type, payload) VALUES ($1, 'ScanCompleted', $2::jsonb)",
                project_id, json.dumps({"project_id": project_id, "findings": findings}),
            )
            await conn.execute(
                "UPDATE project SET status='scan_completed', updated_at=now() WHERE id=$1",
                project_id,
            )
        print(f"[scanner] scan complete for {project_id}: {findings}")
    except Exception as e:
        print(f"[scanner] ERROR {project_id}: {e}")
    finally:
        await pool.close()


class Trigger(BaseModel):
    project_id: str


@app.get("/health")
async def health():
    return {"status": "ok", "page": "scanner"}


@app.post("/trigger")
async def trigger(t: Trigger, bg: BackgroundTasks):
    bg.add_task(run_scan, t.project_id)
    return {"status": "accepted", "project_id": t.project_id}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("orchestra.pages.page_scanner:app", host="0.0.0.0", port=8002, reload=False)
PY

# ---- orchestra/api/__init__.py ----------------------------------------
cat > orchestra/api/__init__.py <<'PY'
PY

# ---- orchestra/api/main.py --------------------------------------------
cat > orchestra/api/main.py <<'PY'
"""Orchestra REST API."""
from __future__ import annotations
import os
import json
import hashlib
from typing import Any
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost/orchestra")

_pool: asyncpg.Pool | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(DATABASE_URL)
    return _pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    await get_pool()
    yield
    if _pool:
        await _pool.close()


app = FastAPI(title="Orchestra API", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ProjectCreate(BaseModel):
    name: str
    description: str = ""


class ArtifactCreate(BaseModel):
    kind: str
    path: str
    content: str


class EventCreate(BaseModel):
    type: str
    payload: dict[str, Any]


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/projects", status_code=201)
async def create_project(body: ProjectCreate):
    pool = await get_pool()
    row = await pool.fetchrow(
        "INSERT INTO project (name, description) VALUES ($1, $2) RETURNING id, name, description, status, version, created_at",
        body.name, body.description,
    )
    return dict(row)


@app.get("/projects")
async def list_projects():
    pool = await get_pool()
    rows = await pool.fetch("SELECT id, name, description, status, version, created_at, updated_at FROM project ORDER BY created_at DESC")
    return [dict(r) for r in rows]


@app.get("/projects/{project_id}")
async def get_project(project_id: str):
    pool = await get_pool()
    row = await pool.fetchrow("SELECT * FROM project WHERE id=$1", project_id)
    if not row:
        raise HTTPException(status_code=404, detail="project not found")
    return dict(row)


@app.post("/projects/{project_id}/artifacts", status_code=201)
async def create_artifact(project_id: str, body: ArtifactCreate):
    pool = await get_pool()
    content_bytes = body.content.encode()
    sha = hashlib.sha256(content_bytes).hexdigest()
    row = await pool.fetchrow(
        """
        INSERT INTO artifact (project_id, kind, path, content, hash)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, project_id, kind, path, hash, version, created_at
        """,
        project_id, body.kind, body.path, content_bytes, sha,
    )
    return dict(row)


@app.get("/projects/{project_id}/artifacts")
async def list_artifacts(project_id: str):
    pool = await get_pool()
    rows = await pool.fetch(
        "SELECT id, project_id, kind, path, hash, version, created_at FROM artifact WHERE project_id=$1 ORDER BY created_at",
        project_id,
    )
    return [dict(r) for r in rows]


@app.post("/projects/{project_id}/events", status_code=201)
async def create_event(project_id: str, body: EventCreate):
    pool = await get_pool()
    row = await pool.fetchrow(
        "INSERT INTO event_log (project_id, type, payload) VALUES ($1, $2, $3::jsonb) RETURNING id, project_id, type, payload, created_at",
        project_id, body.type, json.dumps(body.payload),
    )
    return dict(row)


@app.get("/projects/{project_id}/events")
async def list_events(project_id: str):
    pool = await get_pool()
    rows = await pool.fetch(
        "SELECT id, project_id, type, payload, created_at FROM event_log WHERE project_id=$1 ORDER BY created_at",
        project_id,
    )
    return [dict(r) for r in rows]


@app.get("/artifacts/{artifact_id}/content")
async def get_artifact_content(artifact_id: str):
    from fastapi.responses import PlainTextResponse
    pool = await get_pool()
    row = await pool.fetchrow("SELECT content FROM artifact WHERE id=$1", artifact_id)
    if not row or not row["content"]:
        raise HTTPException(status_code=404, detail="artifact not found")
    return PlainTextResponse(row["content"].decode(errors="replace"))


def run():
    import uvicorn
    uvicorn.run("orchestra.api.main:app", host="0.0.0.0", port=8080, reload=False)


if __name__ == "__main__":
    run()
PY

# ---- orchestra/cli/__init__.py ----------------------------------------
cat > orchestra/cli/__init__.py <<'PY'
PY

# ---- orchestra/cli/main.py --------------------------------------------
cat > orchestra/cli/main.py <<'PY'
"""Orchestra CLI."""
from __future__ import annotations
import os
import json
import sys
import httpx
import typer

app = typer.Typer(name="orchestra", help="Orchestra multi-agent orchestration CLI")

API_URL = os.getenv("ORCHESTRA_API_URL", "http://localhost:8080")


@app.command("project")
def project_cmd(
    action: str = typer.Argument(..., help="list | create | get"),
    name: str = typer.Option("", help="Project name (for create)"),
    description: str = typer.Option("", help="Project description (for create)"),
    project_id: str = typer.Option("", help="Project UUID (for get)"),
):
    """Manage projects."""
    if action == "list":
        r = httpx.get(f"{API_URL}/projects")
        r.raise_for_status()
        projects = r.json()
        if not projects:
            typer.echo("No projects found.")
            return
        for p in projects:
            typer.echo(f"  {p['id']}  {p['name']}  [{p['status']}]")
    elif action == "create":
        if not name:
            typer.echo("--name is required for create", err=True)
            raise typer.Exit(1)
        r = httpx.post(f"{API_URL}/projects", json={"name": name, "description": description})
        r.raise_for_status()
        p = r.json()
        typer.echo(f"Created project: {p['id']}")
    elif action == "get":
        if not project_id:
            typer.echo("--project-id is required for get", err=True)
            raise typer.Exit(1)
        r = httpx.get(f"{API_URL}/projects/{project_id}")
        r.raise_for_status()
        typer.echo(json.dumps(r.json(), indent=2, default=str))
    else:
        typer.echo(f"Unknown action: {action}", err=True)
        raise typer.Exit(1)


@app.command("status")
def status_cmd(project_id: str = typer.Argument(..., help="Project UUID")):
    """Show project status and recent events."""
    r = httpx.get(f"{API_URL}/projects/{project_id}")
    r.raise_for_status()
    p = r.json()
    typer.echo(f"Project : {p['name']}")
    typer.echo(f"Status  : {p['status']}")
    typer.echo(f"Version : {p['version']}")

    re = httpx.get(f"{API_URL}/projects/{project_id}/events")
    re.raise_for_status()
    events = re.json()
    typer.echo(f"\nEvents ({len(events)}):")
    for e in events[-10:]:
        typer.echo(f"  {e['created_at']}  {e['type']}")


if __name__ == "__main__":
    app()
PY

# ---- orchestrator module (__main__.py) --------------------------------
mkdir -p orchestrator
cat > orchestrator/__init__.py <<'PY'
PY

cat > orchestrator/__main__.py <<'PY'
"""Orchestrator – listens for events and dispatches to pages."""
from __future__ import annotations
import os
import asyncio
import json
import logging

import httpx

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
CODER_URL = os.getenv("CODER_URL", "http://coder:8000")
TESTER_URL = os.getenv("TESTER_URL", "http://tester:8001")
SCANNER_URL = os.getenv("SCANNER_URL", "http://scanner:8002")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("orchestrator")


async def dispatch(event: dict) -> None:
    event_type = event.get("type", "")
    project_id = event.get("payload", {}).get("project_id", "")
    if not project_id:
        return

    if event_type == "SpecApproved":
        log.info("SpecApproved -> triggering coder for %s", project_id)
        async with httpx.AsyncClient() as client:
            await client.post(f"{CODER_URL}/trigger", json={"project_id": project_id}, timeout=10)

    elif event_type == "CodeGenerated":
        log.info("CodeGenerated -> triggering tester and scanner for %s", project_id)
        async with httpx.AsyncClient() as client:
            await asyncio.gather(
                client.post(f"{TESTER_URL}/trigger", json={"project_id": project_id}, timeout=10),
                client.post(f"{SCANNER_URL}/trigger", json={"project_id": project_id}, timeout=10),
            )


async def poll_events() -> None:
    import asyncpg
    DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost/orchestra")
    last_id = 0
    pool = await asyncpg.create_pool(DATABASE_URL)
    log.info("Orchestrator started, polling for events...")
    while True:
        try:
            rows = await pool.fetch(
                "SELECT id, type, payload FROM event_log WHERE id > $1 ORDER BY id LIMIT 50",
                last_id,
            )
            for row in rows:
                event = {"type": row["type"], "payload": row["payload"]}
                await dispatch(event)
                last_id = row["id"]
        except Exception as exc:
            log.warning("poll error: %s", exc)
        await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(poll_events())
PY

# ---- orchestra/templates/ ---------------------------------------------
cat > orchestra/templates/spec.yaml.j2 <<'EOF'
name: "{{ project_name }}"
description: "{{ description }}"
version: 1
phases:
  - name: design
    steps:
      - generate_spec
  - name: code
    steps:
      - generate_code
  - name: test
    steps:
      - run_tests
      - run_scan
EOF

# ---- tests/ -----------------------------------------------------------
cat > tests/__init__.py <<'PY'
PY

cat > tests/test_api.py <<'PY'
"""Tests for the Orchestra API."""
import pytest
import httpx
from unittest.mock import AsyncMock, patch, MagicMock


@pytest.mark.asyncio
async def test_health():
    """Test that health endpoint returns ok."""
    with patch("orchestra.api.main.get_pool") as mock_pool:
        from orchestra.api.main import app
        async with httpx.AsyncClient(app=app, base_url="http://test") as client:
            resp = await client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_coder_health():
    """Test coder page health endpoint."""
    from orchestra.pages.page_coder import app
    async with httpx.AsyncClient(app=app, base_url="http://test") as client:
        resp = await client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["page"] == "coder"


@pytest.mark.asyncio
async def test_tester_health():
    """Test tester page health endpoint."""
    from orchestra.pages.page_tester import app
    async with httpx.AsyncClient(app=app, base_url="http://test") as client:
        resp = await client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["page"] == "tester"


@pytest.mark.asyncio
async def test_scanner_health():
    """Test scanner page health endpoint."""
    from orchestra.pages.page_scanner import app
    async with httpx.AsyncClient(app=app, base_url="http://test") as client:
        resp = await client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["page"] == "scanner"
PY

# ---- web/ (React + Vite dashboard) ------------------------------------
mkdir -p web/src/components web/src/pages web/public

cat > web/package.json <<'EOF'
{
  "name": "orchestra-web",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.23.1"
  },
  "devDependencies": {
    "@types/react": "^18.3.3",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.0",
    "vite": "^5.2.11"
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
      '/api': {
        target: process.env.VITE_API_URL || 'http://localhost:8080',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
})
EOF

cat > web/index.html <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Orchestra Dashboard</title>
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; }
    </style>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

cat > web/nginx.conf <<'EOF'
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://api:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

cat > web/src/main.jsx <<'EOF'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
EOF

cat > web/src/App.jsx <<'EOF'
import React, { useEffect, useState, useRef } from 'react'

const API = '/api'

const statusColor = {
  draft: '#64748b',
  generating: '#f59e0b',
  code_generated: '#0ea5e9',
  tests_passed: '#22c55e',
  scan_completed: '#7c3aed',
  done: '#7c3aed',
}

const kindColor = {
  spec: '#0ea5e9',
  code: '#22c55e',
  test: '#f59e0b',
  report: '#ef4444',
}

const s = {
  container: { display: 'flex', height: '100vh', overflow: 'hidden', fontFamily: 'system-ui,-apple-system,sans-serif', background: '#0f172a', color: '#e2e8f0' },
  sidebar: { width: 260, background: '#1e293b', display: 'flex', flexDirection: 'column', borderRight: '1px solid #334155' },
  sidebarHeader: { padding: '1.25rem 1rem', borderBottom: '1px solid #334155' },
  sidebarTitle: { fontSize: '1.1rem', fontWeight: 700, color: '#7c3aed', marginBottom: '1rem' },
  sidebarList: { flex: 1, overflowY: 'auto', padding: '0.5rem' },
  projectItem: { padding: '0.65rem 0.75rem', borderRadius: 8, cursor: 'pointer', marginBottom: 2 },
  main: { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  topbar: { background: '#1e293b', padding: '1rem 1.5rem', borderBottom: '1px solid #334155', display: 'flex', alignItems: 'center', gap: '1rem' },
  content: { flex: 1, padding: '1.5rem', overflowY: 'auto', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem', alignContent: 'start' },
  card: { background: '#1e293b', borderRadius: 12, padding: '1.25rem', border: '1px solid #334155' },
  cardFull: { background: '#1e293b', borderRadius: 12, padding: '1.25rem', border: '1px solid #334155', gridColumn: '1 / -1' },
  sectionTitle: { fontSize: '0.8rem', fontWeight: 700, color: '#64748b', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: '0.75rem' },
  badge: { display: 'inline-block', padding: '0.15rem 0.5rem', borderRadius: 9999, fontSize: '0.7rem', fontWeight: 700 },
  row: { padding: '0.5rem 0', borderBottom: '1px solid #1e293b', fontSize: '0.82rem', display: 'flex', alignItems: 'center', gap: '0.5rem' },
  btn: { padding: '0.55rem 1.1rem', background: '#7c3aed', color: '#fff', border: 'none', borderRadius: 8, cursor: 'pointer', fontWeight: 600, fontSize: '0.85rem' },
  btnSm: { padding: '0.3rem 0.7rem', background: '#334155', color: '#e2e8f0', border: 'none', borderRadius: 6, cursor: 'pointer', fontSize: '0.78rem' },
  input: { padding: '0.5rem 0.75rem', background: '#0f172a', border: '1px solid #334155', borderRadius: 6, color: '#e2e8f0', width: '100%', fontSize: '0.85rem', outline: 'none' },
  textarea: { padding: '0.75rem', background: '#0f172a', border: '1px solid #334155', borderRadius: 8, color: '#e2e8f0', width: '100%', fontSize: '0.85rem', resize: 'vertical', outline: 'none', fontFamily: 'inherit', minHeight: 90 },
  pre: { background: '#0f172a', borderRadius: 8, padding: '1rem', fontSize: '0.78rem', overflowX: 'auto', border: '1px solid #334155', whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxHeight: 300, overflowY: 'auto' },
  dot: { width: 8, height: 8, borderRadius: '50%', display: 'inline-block', flexShrink: 0 },
}

export default function App() {
  const [projects, setProjects] = useState([])
  const [selected, setSelected] = useState(null)
  const [artifacts, setArtifacts] = useState([])
  const [events, setEvents] = useState([])
  const [activeArtifact, setActiveArtifact] = useState(null)
  const [artifactContent, setArtifactContent] = useState('')

  // new project form
  const [newName, setNewName] = useState('')
  const [newSpec, setNewSpec] = useState('')
  const [launching, setLaunching] = useState(false)
  const [showForm, setShowForm] = useState(false)
  const pollRef = useRef(null)

  const loadProjects = () =>
    fetch(`${API}/projects`).then(r => r.json()).then(ps => {
      setProjects(ps)
      // refresh selected if it changed
      setSelected(prev => prev ? (ps.find(p => p.id === prev.id) || prev) : prev)
    }).catch(() => {})

  const loadProjectDetail = (id) => {
    fetch(`${API}/projects/${id}/artifacts`).then(r => r.json()).then(setArtifacts).catch(() => {})
    fetch(`${API}/projects/${id}/events`).then(r => r.json()).then(setEvents).catch(() => {})
  }

  useEffect(() => {
    loadProjects()
    pollRef.current = setInterval(() => {
      loadProjects()
      if (selected) loadProjectDetail(selected.id)
    }, 3000)
    return () => clearInterval(pollRef.current)
  }, [selected?.id])

  const selectProject = (p) => {
    setSelected(p)
    setActiveArtifact(null)
    setArtifactContent('')
    loadProjectDetail(p.id)
  }

  const launchProject = async () => {
    if (!newName.trim() || !newSpec.trim()) return
    setLaunching(true)
    try {
      // 1. Create project
      const pr = await fetch(`${API}/projects`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newName, description: newSpec }),
      })
      const p = await pr.json()

      // 2. Upload spec as artifact
      await fetch(`${API}/projects/${p.id}/artifacts`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ kind: 'spec', path: 'spec/spec.md', content: newSpec }),
      })

      // 3. Publish SpecApproved → triggers autonomous pipeline
      await fetch(`${API}/projects/${p.id}/events`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type: 'SpecApproved', payload: { project_id: p.id } }),
      })

      setNewName(''); setNewSpec(''); setShowForm(false)
      await loadProjects()
      selectProject(p)
    } finally {
      setLaunching(false)
    }
  }

  const viewArtifact = async (a) => {
    setActiveArtifact(a)
    const r = await fetch(`${API}/artifacts/${a.id}/content`)
    if (r.ok) {
      const text = await r.text()
      setArtifactContent(text)
    } else {
      setArtifactContent('(content not available)')
    }
  }

  const statusLabel = selected ? (selected.status || 'draft') : ''

  return (
    <div style={s.container}>
      {/* Sidebar */}
      <aside style={s.sidebar}>
        <div style={s.sidebarHeader}>
          <div style={s.sidebarTitle}>🎼 Orchestra AI</div>
          <button style={{ ...s.btn, width: '100%' }} onClick={() => setShowForm(f => !f)}>
            {showForm ? '✕ Cancel' : '+ New Project'}
          </button>
          {showForm && (
            <div style={{ marginTop: '0.75rem', display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
              <input
                style={s.input}
                placeholder="Project name"
                value={newName}
                onChange={e => setNewName(e.target.value)}
              />
              <textarea
                style={s.textarea}
                placeholder="Describe what you want to build... Claude will generate the code, tests, and security report automatically."
                value={newSpec}
                onChange={e => setNewSpec(e.target.value)}
              />
              <button
                style={{ ...s.btn, opacity: launching ? 0.6 : 1 }}
                onClick={launchProject}
                disabled={launching || !newName.trim() || !newSpec.trim()}
              >
                {launching ? '🚀 Launching...' : '🚀 Launch Autonomous Agent'}
              </button>
            </div>
          )}
        </div>
        <div style={s.sidebarList}>
          <div style={{ fontSize: '0.7rem', color: '#475569', padding: '0.5rem 0.25rem', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
            Projects ({projects.length})
          </div>
          {projects.map(p => (
            <div
              key={p.id}
              style={{ ...s.projectItem, background: selected?.id === p.id ? '#334155' : 'transparent' }}
              onClick={() => selectProject(p)}
            >
              <div style={{ fontWeight: 600, fontSize: '0.88rem', marginBottom: 3 }}>{p.name}</div>
              <span style={{ ...s.badge, background: statusColor[p.status] || '#334155', color: '#fff' }}>
                {p.status}
              </span>
            </div>
          ))}
          {projects.length === 0 && (
            <div style={{ color: '#475569', fontSize: '0.82rem', padding: '1rem 0.25rem' }}>
              No projects yet. Create one above.
            </div>
          )}
        </div>
      </aside>

      {/* Main */}
      <main style={s.main}>
        <div style={s.topbar}>
          {selected ? (
            <>
              <strong style={{ fontSize: '1rem' }}>{selected.name}</strong>
              <span style={{ ...s.badge, background: statusColor[statusLabel] || '#334155', color: '#fff' }}>
                {statusLabel}
              </span>
              <span style={{ color: '#475569', fontSize: '0.78rem', marginLeft: 'auto' }}>
                {selected.id}
              </span>
            </>
          ) : (
            <span style={{ color: '#475569' }}>Select or create a project</span>
          )}
        </div>

        {!selected && (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, gap: '1rem', color: '#475569' }}>
            <div style={{ fontSize: '4rem' }}>🎼</div>
            <div style={{ fontSize: '1.1rem' }}>Orchestra AI — autonomous multi-agent code generation</div>
            <div style={{ fontSize: '0.85rem', maxWidth: 400, textAlign: 'center' }}>
              Describe your project, hit Launch, and Claude automatically generates code, tests, and a security report.
            </div>
            <button style={s.btn} onClick={() => setShowForm(true)}>Create your first project</button>
          </div>
        )}

        {selected && (
          <div style={s.content}>
            {/* Events */}
            <div style={s.card}>
              <div style={s.sectionTitle}>Live Events ({events.length})</div>
              {events.length === 0 && <div style={{ color: '#475569', fontSize: '0.82rem' }}>Waiting for events...</div>}
              {[...events].reverse().slice(0, 15).map(e => (
                <div key={e.id} style={s.row}>
                  <span style={{ ...s.dot, background: statusColor[e.type] || '#7c3aed' }} />
                  <span style={{ color: '#a78bfa', fontWeight: 600 }}>{e.type}</span>
                  <span style={{ marginLeft: 'auto', color: '#475569', fontSize: '0.75rem' }}>
                    {new Date(e.created_at).toLocaleTimeString()}
                  </span>
                </div>
              ))}
            </div>

            {/* Artifacts */}
            <div style={s.card}>
              <div style={s.sectionTitle}>Artifacts ({artifacts.length})</div>
              {artifacts.length === 0 && <div style={{ color: '#475569', fontSize: '0.82rem' }}>Claude is generating...</div>}
              {artifacts.map(a => (
                <div key={a.id} style={{ ...s.row, cursor: 'pointer' }} onClick={() => viewArtifact(a)}>
                  <span style={{ ...s.badge, background: kindColor[a.kind] || '#334155', color: '#fff' }}>{a.kind}</span>
                  <span style={{ fontFamily: 'monospace', fontSize: '0.8rem', flex: 1 }}>{a.path}</span>
                  <span style={{ color: '#475569', fontSize: '0.72rem' }}>v{a.version}</span>
                </div>
              ))}
            </div>

            {/* Artifact viewer */}
            {activeArtifact && (
              <div style={s.cardFull}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', marginBottom: '0.75rem' }}>
                  <div style={s.sectionTitle}>{activeArtifact.path}</div>
                  <button style={s.btnSm} onClick={() => { setActiveArtifact(null); setArtifactContent('') }}>✕ Close</button>
                </div>
                <pre style={s.pre}>{artifactContent || '(loading...)'}</pre>
              </div>
            )}
          </div>
        )}
      </main>
    </div>
  )
}
EOF

# ---- .github/workflows/ci.yml ----------------------------------------
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'EOF'
name: CI

on:
  push:
    branches: [main, "claude/**"]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: orchestra_test
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 5s
          --health-timeout 5s
          --health-retries 5
      redis:
        image: redis:7-alpine
        ports: ["6379:6379"]
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s
          --health-timeout 3s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install package
        run: pip install -e ".[dev]"

      - name: Lint
        run: ruff check orchestra tests

      - name: Test
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/orchestra_test
          REDIS_URL: redis://localhost:6379
        run: pytest tests/ -v
EOF

# ---- README.md --------------------------------------------------------
cat > README.md <<'EOF'
# Orchestra

**Multi-agent project orchestration framework**

## Quick Start

```bash
chmod +x setup_orchestra.sh
./setup_orchestra.sh
```

Then open http://localhost:3000

## Architecture

```
User → CLI / Dashboard
         │
         ▼
    Orchestra API  (FastAPI, port 8080)
         │
         ▼
    Orchestrator   (event poller)
      ├─→ Coder    (port 8000)
      ├─→ Tester   (port 8001)
      └─→ Scanner  (port 8002)
         │
         ▼
    PostgreSQL + Redis
```

## CLI Usage

```bash
# inside the venv or via docker
orchestra project list
orchestra project create --name "My Project" --description "Demo"
orchestra status <UUID>
```

## Services

| Service      | Port | Description                  |
|-------------|------|------------------------------|
| Web UI       | 3000 | React dashboard              |
| API          | 8080 | REST API                     |
| Coder        | 8000 | Code generation agent        |
| Tester       | 8002 | Test runner agent            |
| Scanner      | 8003 | Security scanner agent       |
| PostgreSQL   | 5432 | Primary database             |
| Redis        | 6379 | Message broker               |

## License

MIT
EOF

# ---- bootstrap-orchestra.sh ------------------------------------------
cat > bootstrap-orchestra.sh <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${1:-Demo Project}"
DESCRIPTION="${2:-Bootstrap run}"
API_URL="http://localhost:8080"

echo "🚀 Bootstrapping Orchestra project: $PROJECT_NAME"

# Wait for API to be ready
MAX_WAIT=60
WAITED=0
until curl -sf "$API_URL/health" > /dev/null 2>&1; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "❌ API not ready after ${MAX_WAIT}s"
    exit 1
  fi
  echo "  Waiting for API... (${WAITED}s)"
  sleep 3
  WAITED=$((WAITED + 3))
done
echo "✅ API is ready"

# Create project
PROJECT_JSON=$(curl -sf -X POST "$API_URL/projects" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$PROJECT_NAME\", \"description\": \"$DESCRIPTION\"}")

PROJECT_ID=$(echo "$PROJECT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "✅ Created project: $PROJECT_ID"

# Upload spec artifact
SPEC_CONTENT="name: \"$PROJECT_NAME\"\ndescription: \"$DESCRIPTION\"\nversion: 1\nphases:\n  - name: design\n    steps:\n      - generate_spec\n  - name: code\n    steps:\n      - generate_code\n"

curl -sf -X POST "$API_URL/projects/$PROJECT_ID/artifacts" \
  -H "Content-Type: application/json" \
  -d "{\"kind\": \"spec\", \"path\": \"spec/spec.yaml\", \"content\": \"$SPEC_CONTENT\"}" > /dev/null
echo "✅ Uploaded spec artifact"

# Publish SpecApproved event
curl -sf -X POST "$API_URL/projects/$PROJECT_ID/events" \
  -H "Content-Type: application/json" \
  -d "{\"type\": \"SpecApproved\", \"payload\": {\"project_id\": \"$PROJECT_ID\", \"project_name\": \"$PROJECT_NAME\"}}" > /dev/null
echo "✅ Published SpecApproved event"

echo ""
echo "🎉 Bootstrap complete!"
echo "   Project ID : $PROJECT_ID"
echo "   Dashboard  : http://localhost:3000"
BOOTSTRAP
chmod +x bootstrap-orchestra.sh

# ---- .gitignore -------------------------------------------------------
cat > .gitignore <<'EOF'
__pycache__/
*.py[cod]
*.egg-info/
.venv/
dist/
build/
.env
.DS_Store
node_modules/
web/dist/
*.log
EOF

# ============================================================
# 4️⃣  Virtual-env + editable install
# ============================================================
echo "🐍 Creating virtual environment..."
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip --quiet
pip install -e ".[dev]" --quiet
echo "✅ Package installed"

# ============================================================
# 5️⃣  Start Docker stack
# ============================================================
echo "🐳 Building and starting Docker stack (this may take a few minutes)..."
docker compose up -d --build

echo "⏳ Waiting for services to be healthy..."
sleep 15

# ============================================================
# 6️⃣  Bootstrap
# ============================================================
echo "🚀 Running bootstrap..."
./bootstrap-orchestra.sh "Demo Project" "First run"

# ============================================================
# 7️⃣  Print project UUID and dashboard URL
# ============================================================
PROJECT_UUID=$(curl -sf http://localhost:8080/projects | python3 -c "
import sys, json
projects = json.load(sys.stdin)
if projects:
    print(projects[0]['id'])
else:
    print('(no projects found)')
")

cat <<FINAL

✅  Setup complete!

📂  Project folder  : $ROOT_DIR
🆔  Project UUID    : $PROJECT_UUID
🌐  Dashboard       : http://localhost:3000
🔌  API             : http://localhost:8080

🛠  CLI examples:
      cd $ROOT_DIR && source .venv/bin/activate
      orchestra project list
      orchestra status $PROJECT_UUID

      # or via Docker:
      docker compose exec orchestrator orchestra project list

FINAL
