import anthropic, asyncio, json, os, re, uuid, logging
from orchestra.db import get_pool
from orchestra.broadcast import broadcast
from orchestra.github_client import create_pr, slug

logger = logging.getLogger(__name__)

_SYSTEM = """Você é um desenvolvedor de software especialista. Implemente tarefas completamente com código de qualidade de produção. Comentários e nomes de variáveis em inglês; mensagens de log e commit em português.

Para cada arquivo, use este formato EXATO:
### `caminho/para/arquivo.ext`
```linguagem
<conteúdo do arquivo aqui>
```

Gere código completo e funcional com tratamento de erros adequado. Sem placeholders."""

_REVIEW_SYSTEM = """Você é um revisor de código. Verifique o código fornecido em busca de:
- Erros de sintaxe ou imports quebrados
- SQL injection, segredos hardcoded, brechas óbvias de segurança
- Lógica que claramente contradiz a descrição da tarefa
- Arquivos obrigatórios mencionados na tarefa que estão faltando

Retorne apenas JSON — sem explicação, sem markdown:
{"ok": true}
ou
{"ok": false, "issues": ["descrição concisa de cada problema"]}"""

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

def _review_snippet(files: list) -> str:
    """Build a compact code snippet for the reviewer (max ~4000 chars)."""
    parts = []
    budget = 4000
    for f in files[:5]:
        snippet = f['content'][:min(900, budget)]
        parts.append(f"### `{f['path']}`\n```\n{snippet}\n```")
        budget -= len(snippet)
        if budget <= 0:
            break
    return "\n\n".join(parts)

# Pricing per million tokens
_MODEL_PRICING = {
    "claude-haiku-4-5":  {"in": 0.25,  "out": 1.25},
    "claude-sonnet-4-5": {"in": 3.0,   "out": 15.0},
    "claude-opus-4-5":   {"in": 15.0,  "out": 75.0},
}
_DEFAULT_MODEL = "claude-sonnet-4-5"
_HAIKU_PRICING = _MODEL_PRICING["claude-haiku-4-5"]


async def execute_task(task_id: str, project_id: str) -> None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        task = await conn.fetchrow("SELECT * FROM task WHERE id=$1", task_id)
        if not task:
            return
        order = await conn.fetchrow('SELECT * FROM "order" WHERE id=$1', task['order_id'])
        project = await conn.fetchrow("SELECT * FROM project WHERE id=$1", project_id)

        model = task.get('model') or _DEFAULT_MODEL
        pricing = _MODEL_PRICING.get(model, _MODEL_PRICING[_DEFAULT_MODEL])

        # Budget check before consuming tokens
        if project and project['budget_usd']:
            spent = await conn.fetchval("""
                SELECT COALESCE(SUM(e.cost_usd),0) FROM execution e
                JOIN task t ON t.id = e.task_id
                JOIN "order" o ON o.id = t.order_id
                WHERE o.project_id=$1 AND e.status='completed'
            """, project_id)
            if float(spent or 0) >= float(project['budget_usd']):
                await conn.execute("UPDATE task SET status='failed', updated_at=NOW() WHERE id=$1", task_id)
                await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "failed"})
                await broadcast(project_id, {"type": "activity", "task_id": task_id,
                    "msg": f"Budget limit ${project['budget_usd']} reached — task skipped"})
                return

        await conn.execute("UPDATE task SET status='executing', updated_at=NOW() WHERE id=$1", task_id)
        await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "executing"})
        await broadcast(project_id, {"type": "activity", "task_id": task_id,
            "msg": f"Developer starting [{model.split('-')[1]}]: {task['title']}"})

        exec_id = str(uuid.uuid4())
        await conn.execute("""
            INSERT INTO execution (id, task_id, agent_type, status, input)
            VALUES ($1,$2,$3,'running',$4)
        """, exec_id, task_id, 'developer',
            json.dumps({"title": task['title'], "description": task['description']}))

        client = anthropic.AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
        project_name = project['name'] if project else "Software project"
        github_repo = project['github_repo'] if project else None
        order_title = order['title'] if order else ""
        order_id = str(task['order_id'])

        # Context from completed dependency tasks
        dep_context = ""
        try:
            dep_ids = json.loads(task.get('depends_on') or '[]')
            if dep_ids:
                spec_parts = []
                file_parts = []
                for dep_id in dep_ids:
                    dep = await conn.fetchrow(
                        "SELECT title, result, agent_type FROM task WHERE id=$1 AND status='completed'", dep_id)
                    if not dep:
                        continue
                    try:
                        r = json.loads(dep['result'] or '{}')
                        if dep['agent_type'] == 'architect':
                            # Include actual spec content so developer can follow the design
                            budget = 4000
                            for art in r.get('artifacts', [])[:3]:
                                row = await conn.fetchrow(
                                    "SELECT path, content FROM artifact WHERE id=$1", art['id'])
                                if not row or not row['content']:
                                    continue
                                snippet = row['content'].decode('utf-8', errors='replace')[:budget]
                                spec_parts.append(f"### `{row['path']}`\n{snippet}")
                                budget -= len(snippet)
                                if budget <= 0:
                                    break
                        else:
                            files_list = [a['path'] for a in r.get('artifacts', [])]
                            file_parts.append(f"• {dep['title']}: {', '.join(files_list) if files_list else 'no files'}")
                    except Exception:
                        file_parts.append(f"• {dep['title']}: completed")
                if spec_parts:
                    dep_context += "\n\nArchitecture spec to follow:\n" + "\n\n".join(spec_parts)
                if file_parts:
                    dep_context += "\n\nFiles already created (do not recreate):\n" + "\n".join(file_parts)
        except Exception as e:
            logger.warning(f"Could not load dep context for task={task_id}: {e}")

        repo_hint = f" (GitHub: {github_repo})" if github_repo else ""
        base_prompt = (
            f"Project: {project_name}{repo_hint}\n"
            f"Order: {order_title}\n"
            f"Task: {task['title']}\n"
            f"Details: {task['description']}"
            f"{dep_context}"
        )

        tokens_in = tokens_out = 0
        cost = 0.0

        async def _stream_generate(prompt: str) -> tuple[str, int, int]:
            chunks = []
            async with client.messages.stream(
                model=model, max_tokens=4096,
                system=[{"type": "text", "text": _SYSTEM, "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": prompt}]
            ) as stream:
                char_buf = ""
                async for delta in stream.text_stream:
                    chunks.append(delta)
                    char_buf += delta
                    if len(char_buf) >= 120:
                        preview = char_buf.replace('\n', ' ').strip()[:80]
                        if preview:
                            await broadcast(project_id, {"type": "activity", "task_id": task_id,
                                "msg": f"Writing: {preview}…"})
                        char_buf = ""
                final = await stream.get_final_message()
                return "".join(chunks), final.usage.input_tokens, final.usage.output_tokens

        try:
            # — First pass —
            response_text, ti, to = await _stream_generate(base_prompt)
            tokens_in += ti; tokens_out += to
            cost += (ti * pricing["in"] + to * pricing["out"]) / 1_000_000
            files = _parse_files(response_text)

            # — Review pass (Haiku, cheap) —
            if files:
                await broadcast(project_id, {"type": "activity", "task_id": task_id,
                    "msg": f"Reviewing {len(files)} file(s)…"})
                snippet = _review_snippet(files)
                review_task_ctx = f"Task: {task['title']}\nDetails: {task['description']}\n\nGenerated code:\n{snippet}"
                try:
                    rev_msg = await client.messages.create(
                        model="claude-haiku-4-5", max_tokens=300,
                        system=_REVIEW_SYSTEM,
                        messages=[{"role": "user", "content": review_task_ctx}])
                    rev_text = rev_msg.content[0].text.strip()
                    rev_text = re.sub(r'^```[a-z]*\n?', '', rev_text)
                    rev_text = re.sub(r'\n?```$', '', rev_text)
                    review = json.loads(rev_text)
                    rev_ti = rev_msg.usage.input_tokens
                    rev_to = rev_msg.usage.output_tokens
                    tokens_in += rev_ti; tokens_out += rev_to
                    cost += (rev_ti * _HAIKU_PRICING["in"] + rev_to * _HAIKU_PRICING["out"]) / 1_000_000
                except Exception as re_err:
                    logger.warning(f"Review parse failed: {re_err}")
                    review = {"ok": True}

                if not review.get("ok") and review.get("issues"):
                    issues = review["issues"]
                    issues_summary = "; ".join(str(i) for i in issues[:3])
                    await broadcast(project_id, {"type": "activity", "task_id": task_id,
                        "msg": f"Issues found — fixing: {issues_summary[:100]}"})
                    logger.info(f"Review found {len(issues)} issue(s) in task={task_id}, re-generating")

                    # — Fix pass —
                    issues_text = "\n".join(f"- {i}" for i in issues)
                    fix_prompt = base_prompt + f"\n\nIMPORTANT — fix these issues in your implementation:\n{issues_text}"
                    response_text2, ti2, to2 = await _stream_generate(fix_prompt)
                    tokens_in += ti2; tokens_out += to2
                    cost += (ti2 * pricing["in"] + to2 * pricing["out"]) / 1_000_000
                    files2 = _parse_files(response_text2)
                    if files2:
                        files = files2
                        response_text = response_text2
                    await broadcast(project_id, {"type": "activity", "task_id": task_id,
                        "msg": f"Fixed and re-generated {len(files)} file(s)"})
                else:
                    await broadcast(project_id, {"type": "activity", "task_id": task_id,
                        "msg": "Code review passed ✓"})

        except Exception as e:
            logger.error(f"Developer failed task={task_id}: {e}")
            await conn.execute("UPDATE task SET status='failed', updated_at=NOW() WHERE id=$1", task_id)
            await conn.execute("UPDATE execution SET status='failed', finished_at=NOW() WHERE id=$1", exec_id)
            await broadcast(project_id, {"type": "task_updated", "task_id": task_id, "status": "failed"})
            return

        await broadcast(project_id, {"type": "activity", "task_id": task_id,
            "msg": f"Done — {len(files)} file(s) · ${cost:.4f} ({tokens_in+tokens_out} tokens)"})

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

        pr_url = None
        if github_repo and files:
            try:
                await broadcast(project_id, {"type": "activity", "task_id": task_id,
                    "msg": f"Opening PR on {github_repo}..."})
                branch_name = f"orchestra/{order_id[:8]}/{slug(task['title'])}"
                pr_body = (
                    f"Generated by Orchestra\n\n"
                    f"**Order:** {order_title}\n"
                    f"**Task:** {task['title']}\n\n"
                    f"{task['description'] or ''}"
                )
                pr_url = await asyncio.to_thread(create_pr, github_repo, branch_name, task['title'], pr_body, files)
                logger.info(f"PR created: {pr_url}")
            except Exception as pr_err:
                logger.warning(f"PR creation failed for task={task_id}: {pr_err}")

        result = json.dumps({"artifacts": artifact_ids, "files": len(files), "pr_url": pr_url})
        await conn.execute(
            "UPDATE task SET status='completed', result=$1, github_pr_url=$2, updated_at=NOW() WHERE id=$3",
            result, pr_url, task_id)
        await broadcast(project_id, {
            "type": "task_updated", "task_id": task_id,
            "status": "completed", "artifacts": artifact_ids,
            "github_pr_url": pr_url,
            "cost_usd": float(cost),
            "tokens": tokens_in + tokens_out
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
