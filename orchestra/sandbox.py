import asyncio, os, tempfile, logging
from orchestra.db import get_pool

logger = logging.getLogger(__name__)


async def run_task_artifacts(task_id: str) -> dict:
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """SELECT DISTINCT ON (path) path, content
               FROM artifact WHERE task_id=$1 AND kind='code'
               ORDER BY path, version DESC, created_at DESC""", task_id)

    if not rows:
        return {"ok": False, "output": "Nenhum arquivo de código encontrado para esta task."}

    with tempfile.TemporaryDirectory() as tmpdir:
        for row in rows:
            dest = os.path.join(tmpdir, row['path'])
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            content = row['content'] if isinstance(row['content'], bytes) else row['content'].encode()
            with open(dest, 'wb') as f:
                f.write(content)

        py_files = [r['path'] for r in rows if r['path'].endswith('.py')]
        priority = ('main.py', 'app.py', 'index.py', 'run.py', 'server.py')
        entry = next((p for p in py_files if os.path.basename(p) in priority), None)
        if not entry and py_files:
            entry = py_files[0]

        if not entry:
            return {"ok": False, "output": "Nenhum arquivo .py encontrado para executar."}

        entry_abs = os.path.join(tmpdir, entry)
        logger.info(f"sandbox: running {entry} for task={task_id}")

        try:
            proc = await asyncio.create_subprocess_exec(
                'python3', '-I', entry_abs,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=tmpdir,
                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30.0)
            out = stdout.decode('utf-8', errors='replace')
            err = stderr.decode('utf-8', errors='replace')
            combined = out
            if err.strip():
                combined += ('\n' if combined else '') + '[stderr]\n' + err
            return {
                "ok": proc.returncode == 0,
                "exit_code": proc.returncode,
                "output": combined.strip()[:4000] or '(sem saída)',
            }
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            return {"ok": False, "output": "Tempo limite de 30 segundos excedido."}
        except Exception as e:
            logger.error(f"sandbox error task={task_id}: {e}")
            return {"ok": False, "output": f"Erro ao executar: {e}"}
