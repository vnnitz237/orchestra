# Orchestra — CLAUDE.md

> **Leia este arquivo inteiro antes de fazer qualquer mudança.**
> Este documento é a fonte única de verdade do projeto. Foi escrito para ser lido por qualquer IA (Claude, ChatGPT, Gemini, etc.) ou humano que precise continuar o desenvolvimento sem histórico de conversa anterior.
> Se você é uma IA: siga as restrições de segurança à risca, nunca faça push para main/master, nunca use `docker compose down -v`.

---

## O que é o Orchestra

Orchestra é uma plataforma web de orquestração de agentes de IA. O usuário cria **projetos**, envia **pedidos** em linguagem natural, e uma equipe de agentes autônomos (powered by Anthropic Claude) planeja e executa as tarefas, gerando código, specs e testes — e opcionalmente abrindo PRs no GitHub.

Interface: estilo WhatsApp/chat lateral + painel de execução com DAG de tarefas, progresso em tempo real via WebSocket.

---

## Stack

| Camada | Tecnologia |
|--------|-----------|
| Backend API | FastAPI (Python 3.11+) |
| Banco de dados | PostgreSQL (asyncpg) |
| Filas/pub-sub | Redis |
| Agentes IA | Anthropic SDK (AsyncAnthropic) |
| Frontend | React 18 + Vite (SPA) |
| WebSocket | FastAPI WebSocket + Redis pub/sub relay |
| Container | Docker Compose |

---

## Estrutura de arquivos

```
orchestra/
├── CLAUDE.md                    ← este arquivo
├── docker-compose.yml
├── .env                         ← ANTHROPIC_API_KEY, GITHUB_TOKEN (nunca commitar)
├── orchestra/                   ← pacote Python
│   ├── api/
│   │   └── main.py              ← FastAPI app, todas as rotas REST + WS
│   ├── agents/
│   │   ├── coordinator.py       ← Atlas: interpreta pedido, cria tasks (AsyncAnthropic)
│   │   ├── architect.py         ← Lia: gera spec técnica (AsyncAnthropic, streaming)
│   │   ├── developer.py         ← Tec: gera código (AsyncAnthropic, streaming, review pass)
│   │   ├── tester.py            ← Finn: gera testes (AsyncAnthropic, streaming)
│   │   └── dispatch.py          ← roteador de agentes com auto-retry (até 2x, backoff exp.)
│   ├── sandbox.py               ← executa artefatos Python em subprocesso isolado (novo)
│   ├── db.py                    ← pool asyncpg
│   ├── broadcast.py             ← publica eventos no Redis → WebSocket
│   ├── ws.py                    ← ConnectionManager WebSocket
│   └── github_client.py         ← cria branches e PRs via PyGithub (síncrono)
└── web/                         ← SPA React
    └── src/
        ├── App.jsx              ← componente único (todos os componentes inline)
        └── App.css              ← design system completo (tokens CSS, temas dark/light)
```

---

## Modelo de dados

```
project
  id, name, description, github_repo
  autonomy: 'delegated' | 'supervised' | 'planning'
  budget_usd: decimal (nullable)
  notification_email: text (nullable)

order  (pedido do usuário)
  id, project_id, title, description
  status: 'pending' | 'analyzing' | 'executing' | 'awaiting_approval' | 'completed' | 'failed'

task   (unidade de trabalho de um agente)
  id, order_id, project_id
  agent_type: 'coordinator' | 'architect' | 'developer' | 'tester'
  model: 'claude-haiku-4-5' | 'claude-sonnet-4-5' | 'claude-opus-4-5'
  status: 'pending' | 'executing' | 'completed' | 'failed'
  depends_on: JSONB []  ← IDs de tasks que precisam completar antes
  sort_order, result (JSONB), github_pr_url

execution  (log de cada run de uma task)
  id, task_id, agent_type, status, input, output (truncado 8000 chars), cost_usd, tokens_used

artifact   (arquivo gerado)
  id, project_id, task_id
  kind: 'code' | 'spec' | 'test', version
  path, content (bytea)
```

---

## Equipe de agentes

| ID | Nome | Papel | Cor UI | Modelo padrão |
|----|------|-------|--------|---------------|
| `coordinator` | Atlas | Coordenador — decompõe pedido em tasks | `#2563EB` | claude-haiku-4-5 |
| `architect` | Lia | Arquiteta — gera spec técnica | `#7C3AED` | claude-sonnet-4-5 |
| `developer` | Tec | Desenvolvedor — gera código + review pass | `#00B978` | claude-sonnet-4-5 |
| `tester` | Finn | Testador — gera suítes pytest | `#F59E0B` | claude-haiku-4-5 |

### Fluxo de execução

```
POST /api/projects/{id}/orders
  └─ coordinator.process_order(order_id)
       └─ cria tasks no DB (com depends_on DAG)
       └─ se autonomy='planning' → order.status='awaiting_approval' (aguarda /approve)
       └─ senão → _execute_dag(task_ids, task_deps, project_id)
            └─ para cada camada do DAG (tasks sem deps pendentes):
                 └─ dispatch.dispatch_task(task_id, project_id)
                      └─ roteamento por agent_type
                      └─ retry automático até 2x com backoff (2s, 4s)
                           └─ architect/developer/tester.execute_task()
```

---

## Padrões críticos de código

### Async obrigatório
Todos os agentes usam `anthropic.AsyncAnthropic` (nunca `anthropic.Anthropic` síncrono).
Chamadas síncronas de I/O devem ser envolvidas em `asyncio.to_thread()`.

```python
# CORRETO
client = anthropic.AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"], timeout=180.0)
msg = await client.messages.create(...)

# CORRETO para código síncrono (ex: github_client.create_pr)
pr_url = await asyncio.to_thread(create_pr, github_repo, branch, title, body, files)

# ERRADO — bloqueia o event loop
client = anthropic.Anthropic(...)
msg = client.messages.create(...)
```

### Broadcast de eventos WebSocket
Use sempre `await broadcast(project_id, {...})` de `orchestra.broadcast`.
Não acesse o manager diretamente dos agentes.

### React: efeitos colaterais fora de state updaters
`addToast()` e outras chamadas com efeitos colaterais NUNCA dentro de `setOrders(prev => ...)`.
Use `ordersRef.current` para leitura do estado atual sem re-render.

```javascript
// CORRETO
const order = ordersRef.current.find(o => o.id === ev.order_id)
addToast('título', order?.title, 'success')
setOrders(prev => prev.map(...))

// ERRADO — side effect dentro de updater dispara 2x no React 18 strict mode
setOrders(prev => {
  addToast(...)   // ← NÃO FAZER
  return prev.map(...)
})
```

---

## Restrições de segurança — NUNCA violar

1. **`ANTHROPIC_API_KEY` e `GITHUB_TOKEN`** ficam em `~/orchestra/.env`. Nunca em código-fonte.
2. **Nunca fazer push para main/master.** Branch de desenvolvimento: `claude/beautiful-feynman-svm3hg`
3. **Nunca usar `docker compose down -v`** — isso destrói o volume `pgdata` com todos os dados.

---

## Branch ativa e estado do git

```
branch: claude/beautiful-feynman-svm3hg
remote: origin → https://github.com/vnnitz237/orchestra
```

Para continuar de qualquer IA/sessão nova:
```bash
git clone https://github.com/vnnitz237/orchestra
cd orchestra
git checkout claude/beautiful-feynman-svm3hg
```

> **Nota:** O desenvolvimento iniciado no Claude Code (Anthropic) continuará no ChatGPT ou outra IA. Este CLAUDE.md garante continuidade total — toda decisão de arquitetura, padrão de código e restrição de segurança está documentada aqui.

---

## Como rodar localmente

```bash
cd ~/orchestra
cp .env.example .env    # preencha ANTHROPIC_API_KEY e GITHUB_TOKEN
docker compose up --build
# Abre: http://localhost:5173  (frontend Vite dev server)
# API:   http://localhost:8000
```

### Testes
```bash
pip install -e '.[dev]'
pytest
cd web && npm ci && npm run build
```

---

## Rotas da API

| Método | Rota | Descrição |
|--------|------|-----------|
| GET | `/api/projects` | Lista projetos com order_count e total_cost |
| POST | `/api/projects` | Cria projeto |
| PATCH | `/api/projects/{id}` | Atualiza autonomia e budget |
| GET | `/api/projects/{id}` | Projeto + orders |
| POST | `/api/projects/{id}/orders` | Cria pedido → dispara coordinator |
| GET | `/api/orders/{id}/tasks` | Tasks com cost_usd, tokens_used, last_error |
| POST | `/api/orders/{id}/approve` | Aprova execução (autonomy=planning) |
| GET | `/api/orders/{id}/cost` | Custo total do pedido |
| GET | `/api/orders/{id}/notifications` | Entregas de notificação do pedido |
| POST | `/api/tasks/{id}/retry` | Retenta task com status 'failed' |
| POST | `/api/tasks/{id}/execute` | Executa artefatos Python em sandbox (novo) |
| GET | `/api/projects/{id}/artifacts` | Lista artefatos |
| GET | `/api/artifacts/{id}/versions` | Histórico de versões do artefato |
| GET | `/api/projects/{id}/artifacts/download` | ZIP de todos artefatos |
| GET | `/api/orders/{id}/artifacts/download` | ZIP de artefatos do pedido |
| GET | `/api/artifacts/{id}/content` | Conteúdo texto de um artefato |
| WS | `/ws/{project_id}` | WebSocket tempo real |
| GET | `/health` | Health check |

---

## Eventos WebSocket

O backend publica via Redis → relay → todos os clientes conectados ao projeto.

| `type` | Campos relevantes |
|--------|-------------------|
| `order_updated` | `order_id`, `status` |
| `task_created` | `task` (objeto completo) |
| `task_updated` | `task_id`, `status`, `github_pr_url`, `cost_usd`, `tokens`, `error` |
| `activity` | `task_id`, `msg` (streaming preview do agente) |
| `sandbox_start` | `task_id` (execução iniciada) |
| `sandbox_result` | `task_id`, `ok` (bool), `output` (string), `exit_code` |

---

## Frontend — componentes principais (App.jsx)

| Componente | Função |
|-----------|--------|
| `ToastStack` | Notificações flutuantes (success/error/info, 5s auto-dismiss) |
| `AgentAvatar` | SVG do agente por tipo (`coordinator/architect/developer/tester`) |
| `StatusPill` | Badge de status traduzido para português |
| `ChatMessage` | Par mensagem-usuário + resposta-Atlas |
| `Composer` | Textarea com auto-resize, Enter envia, Shift+Enter nova linha |
| `PlanStep` | Linha de task: retry, botão "▶ Executar" (developer), terminal de output |
| `ExecutionPanel` | Painel direito: status, tarefas, artefatos, custo |
| `AgentStrip` | Linha de agentes com status de atividade |

### Scroll do chat
O container `.rq-messages` usa `ref={messagesRef}`.
Scroll para o fim: `messagesRef.current.scrollTop = messagesRef.current.scrollHeight`.
Disparado ao: criar order, receber activity log, via `scrollToBottom` callback.

---

## Features implementadas

- [x] Criação de projetos com GitHub repo, autonomia e budget
- [x] Envio de pedidos em linguagem natural
- [x] Coordinator (Atlas) decompõe pedido em tasks via DAG
- [x] Três modos de autonomia: delegado, supervisionado, planejamento (com aprovação)
- [x] Limite de budget com verificação antes de cada task
- [x] Agentes com streaming de output (Lia, Tec, Finn)
- [x] Review pass do código gerado (claude-haiku-4-5, barato)
- [x] Auto-retry com backoff exponencial (dispatch.py, até 2x)
- [x] Timeout de 180s em todos os agentes
- [x] Criação automática de PRs no GitHub (developer)
- [x] Download de artefatos em ZIP (por pedido ou projeto)
- [x] Toast notifications (order completed/failed/awaiting_approval)
- [x] Exibição de `last_error` em tasks com falha
- [x] Custo total por projeto no card da home
- [x] Interface 100% em português
- [x] Scroll automático do chat (estilo WhatsApp)
- [x] Dark mode automático via `prefers-color-scheme: dark` (tokens CSS)
- [x] Animações de entrada nas mensagens, hover lift nos cards
- [x] Spin ring no ícone de tasks em execução
- [x] Execução de artefatos Python em sandbox isolado (`POST /api/tasks/{id}/execute`)
- [x] Terminal inline no painel de tasks com output da execução
- [x] Histórico de versões de artefatos por task, tipo e caminho

---

## Sandbox de execução

O endpoint `POST /api/tasks/{task_id}/execute` executa artefatos `kind='code'` gerados pelo agente developer.

**Restrições:**
- Apenas tasks com `status='completed'` e `agent_type='developer'`
- `python3 -I` — modo isolado (ignora site-packages do usuário)
- Timeout de 30 segundos
- Output truncado em 4000 chars
- Executa em `tempfile.TemporaryDirectory` (descartado após)

**Fluxo:**
1. Backend envia `sandbox_start` via WebSocket
2. `sandbox.run_task_artifacts()` extrai arquivos, escolhe entry point
3. Entry point: `main.py` > `app.py` > `index.py` > `run.py` > `server.py` > primeiro `.py`
4. Backend envia `sandbox_result` com `ok`, `output`, `exit_code`

**Frontend (`sandboxes` state):**
```javascript
const [sandboxes, setSandboxes] = useState({})
// { [task_id]: { status: 'running' | 'done', ok: bool, output: string } }
```

---

## SDK dos agentes — referência neutra

Os agentes usam a biblioteca `anthropic` (Python). Esta seção explica a interface de forma independente de qual IA está lendo.

### Instalação
```
pip install anthropic
```

### Cliente assíncrono (obrigatório — nunca use o síncrono)
```python
import anthropic, os

client = anthropic.AsyncAnthropic(
    api_key=os.environ["ANTHROPIC_API_KEY"],
    timeout=180.0   # segundos — sempre definir
)
```

### Criar uma mensagem (aguardar resposta completa)
```python
msg = await client.messages.create(
    model="claude-haiku-4-5",   # ou claude-sonnet-4-5 / claude-opus-4-5
    max_tokens=4096,
    system="Você é um assistente...",   # string simples ou lista de blocos
    messages=[{"role": "user", "content": "Olá"}]
)
text = msg.content[0].text
tokens_in  = msg.usage.input_tokens
tokens_out = msg.usage.output_tokens
```

### Streaming (usado em architect, developer, tester)
```python
chunks = []
async with client.messages.stream(
    model="claude-sonnet-4-5",
    max_tokens=4096,
    system=[{"type": "text", "text": "...", "cache_control": {"type": "ephemeral"}}],
    messages=[{"role": "user", "content": prompt}]
) as stream:
    async for delta in stream.text_stream:
        chunks.append(delta)
        # delta é um fragmento de string — use para transmitir via WebSocket
    final = await stream.get_final_message()
    tokens_in  = final.usage.input_tokens
    tokens_out = final.usage.output_tokens

response_text = "".join(chunks)
```

### Modelos disponíveis e preços (por milhão de tokens)
| Modelo | Input | Output | Uso nos agentes |
|--------|-------|--------|-----------------|
| `claude-haiku-4-5` | $0.25 | $1.25 | Coordinator, Tester, Review pass |
| `claude-sonnet-4-5` | $3.00 | $15.00 | Architect, Developer (padrão) |
| `claude-opus-4-5` | $15.00 | $75.00 | Tarefas complexas (sob demanda) |

### Cálculo de custo
```python
cost = (tokens_in * preco_in + tokens_out * preco_out) / 1_000_000
```

### Cache de prompt (reduz custo em chamadas repetidas)
Adicionar `"cache_control": {"type": "ephemeral"}` ao bloco de system prompt
faz a API cachear o prefixo por até 5 minutos. Usado em todos os agentes.

### Chamada síncrona dentro de contexto async
`github_client.create_pr()` usa `PyGithub` que é síncrono. Para não bloquear
o event loop do FastAPI, envolva em `asyncio.to_thread`:
```python
import asyncio
result = await asyncio.to_thread(funcao_sincrona, arg1, arg2)
```

---

## Próximas etapas sugeridas

- [x] Histórico de versões de artefatos por task
- [x] Notificações por e-mail ao concluir ou falhar pedidos
- [x] Notificações locais do navegador via Web Notification API
- [ ] Painel de configuração de agentes (trocar modelo por task)
- [ ] Suporte a múltiplos usuários / autenticação

---

## Atribuição para commits e PRs

Adapte conforme a IA usada na sessão. Exemplos:

**Claude Code:**
```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

**ChatGPT / outros:**
```
Co-Authored-By: AI Assistant <noreply@openai.com>
```

Todo PR deve identificar a IA usada na descrição.

---

## Histórico de sessões

| Data | IA | Trabalho realizado |
|------|----|--------------------|
| 2026-10 | Claude Sonnet 4.6 (Anthropic) | Setup inicial, todos os agentes, scroll fix, dark mode → branco definitivo, sandbox execution |
| próxima | ChatGPT | a definir |
