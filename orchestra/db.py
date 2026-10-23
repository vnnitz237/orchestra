import asyncpg, os, uuid

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


async def create_artifact(conn, project_id: str, task_id: str, kind: str,
                          path: str, content: bytes) -> dict:
    """Persist an artifact as the next version for its task and path."""
    lock_key = f"artifact:{task_id}:{kind}:{path}"
    async with conn.transaction():
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext($1))", lock_key)
        version = await conn.fetchval("""
            SELECT COALESCE(MAX(version), 0) + 1
            FROM artifact
            WHERE task_id=$1 AND kind=$2 AND path=$3
        """, task_id, kind, path)
        artifact_id = str(uuid.uuid4())
        await conn.execute("""
            INSERT INTO artifact (id, project_id, task_id, kind, path, content, version)
            VALUES ($1,$2,$3,$4,$5,$6,$7)
        """, artifact_id, project_id, task_id, kind, path, content, version)
    return {"id": artifact_id, "path": path, "version": version}
