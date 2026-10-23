import { useState, useEffect, useRef, useCallback } from 'react'

// ─── Agent Definitions ────────────────────────────────────────────────────────
const AGENTS = {
  coordinator: { name: 'Atlas', role: 'Coordenador', color: '#2563EB' },
  architect:   { name: 'Lia',   role: 'Arquiteta',   color: '#7C3AED' },
  developer:   { name: 'Tec',   role: 'Desenvolvedor', color: '#00B978' },
  tester:      { name: 'Finn',  role: 'Testador',    color: '#F59E0B' },
}

const AV_COLORS = ['#2563EB','#00B978','#F59E0B','#7C3AED','#e11d48','#0891b2','#ea580c','#16a34a']
function avatarColor(s=''){let h=0;for(let i=0;i<s.length;i++)h=s.charCodeAt(i)+((h<<5)-h);return AV_COLORS[Math.abs(h)%AV_COLORS.length]}
function initials(s=''){return s.split(' ').slice(0,2).map(w=>w[0]||'').join('').toUpperCase()||'?'}

// ─── Agent SVG Avatars ────────────────────────────────────────────────────────
function AgentAvatar({ type = 'coordinator', size = 32 }) {
  const ag = AGENTS[type] || AGENTS.coordinator
  const c = ag.color
  // All shapes use viewBox="0 0 40 40" with two capsule eyes
  const eyesY = type === 'architect' ? 24 : 18
  return (
    <svg viewBox="0 0 40 40" width={size} height={size} aria-label={ag.name} style={{ flexShrink: 0 }}>
      {type === 'coordinator' && (
        <path d="M20 4 C21 10 18 14 22 17 C27 19 36 18 36 20 C36 22 27 21 22 23 C18 26 21 30 20 36 C19 30 22 26 18 23 C13 21 4 22 4 20 C4 18 13 19 18 17 C22 14 19 10 20 4Z" fill={c}/>
      )}
      {type === 'architect' && (
        <path d="M20 5 L35 33 Q35 36 31 36 L9 36 Q5 36 5 33Z" fill={c}/>
      )}
      {type === 'developer' && (
        <path d="M13 7 C7 9 4 16 5 22 C6 29 11 35 18 36 C25 37 33 31 35 24 C37 17 33 9 27 7 C21 5 16 6 13 7Z" fill={c}/>
      )}
      {type === 'tester' && (
        <path d="M20 5 L32 12 L32 28 L20 35 L8 28 L8 12Z" fill={c}/>
      )}
      <rect x="12.5" y={eyesY} width="5" height="8" rx="2.5" fill="white"/>
      <rect x="22.5" y={eyesY} width="5" height="8" rx="2.5" fill="white"/>
    </svg>
  )
}

// Fallback initials avatar for project cards
function InitialsAvatar({ name, size = 44 }) {
  const bg = avatarColor(name)
  return (
    <div className="rq-project-avatar" style={{ background: bg, width: size, height: size }}>
      {initials(name)}
    </div>
  )
}

// ─── Status Pill ──────────────────────────────────────────────────────────────
const PILL_MAP = {
  pending:           'Pendente',
  analyzing:         'Analisando',
  executing:         'Executando',
  completed:         'Concluído',
  failed:            'Falhou',
  blocked:           'Bloqueado',
  awaiting_approval: 'Aguardando Aprovação',
}
function StatusPill({ status }) {
  const cls = `rq-pill rq-pill--${status}`
  return <span className={cls}><span className="rq-pill-dot"/>{PILL_MAP[status]||status}</span>
}

// ─── Artifact Modal ───────────────────────────────────────────────────────────
function ArtifactModal({ artifact, onClose }) {
  const [content, setContent] = useState('Carregando…')
  useEffect(() => {
    fetch(`/api/artifacts/${artifact.id}/content`)
      .then(r => r.text()).then(setContent).catch(() => setContent('Falha ao carregar'))
  }, [artifact.id])
  return (
    <div className="rq-overlay" onClick={onClose}>
      <div className="rq-modal rq-modal-wide" onClick={e => e.stopPropagation()}>
        <div className="rq-modal-header">
          <span className="rq-modal-title">{artifact.path}</span>
          <button className="rq-icon-btn" onClick={onClose} aria-label="Fechar">✕</button>
        </div>
        <pre className="rq-code-block">{content}</pre>
      </div>
    </div>
  )
}

// ─── Plan Step (task in execution panel) ─────────────────────────────────────
function PlanStep({ task, onRetry }) {
  const iconMap = { completed: '✓', executing: '●', failed: '✕', pending: '', analyzing: '●' }
  const icon = iconMap[task.status] || ''
  const ag = AGENTS[task.agent_type] || AGENTS.developer
  return (
    <div className="rq-plan-step">
      <span className={`rq-step-icon ${task.status}`}>{icon}</span>
      <div className="rq-step-body">
        <div className="rq-step-title">{task.title}</div>
        <div className="rq-step-meta-row">
          <span className="rq-agent-badge" style={{ '--ag-col': ag.color }}>{ag.name}</span>
          {task.model && (
            <span className="rq-model-badge">{task.model.replace('claude-','').replace('-4-5','')}</span>
          )}
          {task.cost_usd > 0 && (
            <span className="rq-cost-badge">${Number(task.cost_usd).toFixed(4)}</span>
          )}
          {task.github_pr_url && (
            <a className="rq-pr-link" href={task.github_pr_url} target="_blank" rel="noreferrer">↗ PR</a>
          )}
          {task.status === 'failed' && onRetry && (
            <button className="rq-retry-btn" onClick={() => onRetry(task.id)}>↺ Tentar novamente</button>
          )}
        </div>
      </div>
      <StatusPill status={task.status}/>
    </div>
  )
}

// ─── Execution Panel ──────────────────────────────────────────────────────────
function ExecutionPanel({ order, tasks, cost, artifacts, projectId, onApprove, onRetry, onArtifactClick, isConnected }) {
  if (!order) {
    return (
      <div className="rq-exec-empty">
        <div className="rq-exec-empty-title">Painel de execução</div>
        <div className="rq-exec-empty-desc">Selecione uma conversa para ver detalhes das tarefas, etapas do plano e arquivos gerados.</div>
      </div>
    )
  }

  const done = tasks.filter(t => t.status === 'completed').length
  const isActive = ['pending','analyzing','executing','awaiting_approval'].includes(order.status)
  const orderArtifacts = artifacts.filter(a => tasks.some(t => t.id === a.task_id))

  return (
    <>
      <div className="rq-exec-header">
        <div>
          <div className="rq-exec-title">Painel de execução</div>
          <div className="rq-exec-order-title">{order.title}</div>
        </div>
        <div className="rq-live-indicator">
          <div className={`rq-live-dot${isActive && isConnected ? ' pulse' : isActive ? '' : ' off'}`}/>
          <span className="rq-live-label">
            {isActive && isConnected ? 'Ao vivo' : isActive ? 'Reconectando' : 'Concluído'}
          </span>
        </div>
      </div>

      {/* Status */}
      <div className="rq-exec-section" style={{ paddingTop: 12, paddingBottom: 12 }}>
        <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between' }}>
          <StatusPill status={order.status}/>
          {tasks.length > 0 && (
            <span style={{ font:'400 12px/18px var(--rq-font)', color:'var(--rq-muted)' }}>
              {done}/{tasks.length} tarefas
            </span>
          )}
        </div>
      </div>

      {/* Approval */}
      {order.status === 'awaiting_approval' && (
        <div className="rq-exec-section">
          <div className="rq-section-label">Sua decisão</div>
          <div className="rq-approval">
            <div className="rq-approval-title">Aprovar plano de execução</div>
            <div className="rq-approval-desc">
              {tasks.length} tarefa{tasks.length !== 1 ? 's' : ''} planejada{tasks.length !== 1 ? 's' : ''}. Revise abaixo e aprove para iniciar a execução.
            </div>
            <button className="rq-approve-btn" onClick={() => onApprove(order.id)}>
              ✓ Aprovar e Executar
            </button>
          </div>
        </div>
      )}

      {/* Plan steps */}
      {tasks.length > 0 && (
        <div className="rq-exec-section">
          <div className="rq-section-label">Plano · {tasks.length} etapa{tasks.length !== 1 ? 's' : ''}</div>
          <div className="rq-plan-steps">
            {tasks.map(t => <PlanStep key={t.id} task={t} onRetry={onRetry}/>)}
          </div>
        </div>
      )}

      {/* Artifacts */}
      {orderArtifacts.length > 0 && (
        <div className="rq-exec-section">
          <div className="rq-section-label">Arquivos gerados · {orderArtifacts.length}</div>
          <div className="rq-artifact-list">
            {orderArtifacts.slice(0,12).map(a => {
              const icon = a.kind === 'test' ? '🧪' : a.kind === 'spec' ? '📐' : '📄'
              return (
                <div key={a.id} className="rq-artifact-row" onClick={() => onArtifactClick(a)}>
                  <span style={{ fontSize:11 }}>{icon}</span>
                  <span className="rq-artifact-path">{a.path}</span>
                  {a.kind !== 'code' && <span className="rq-artifact-kind">{a.kind}</span>}
                </div>
              )
            })}
          </div>
          <div className="rq-artifact-actions">
            <a className="rq-zip-btn" href={`/api/orders/${order.id}/artifacts/download`} download>
              ⬇ Baixar ZIP
            </a>
          </div>
        </div>
      )}

      {/* Próxima decisão — when a task is executing and order awaits approval */}
      {order.status === 'executing' && tasks.some(t => t.status === 'executing') && (
        <div className="rq-exec-section">
          <div className="rq-next-decision">
            <div className="rq-next-decision-label">Próxima decisão</div>
            <div className="rq-next-decision-text">
              {tasks.find(t => t.status === 'executing')?.title || 'Em execução…'}
            </div>
          </div>
        </div>
      )}

      {/* Budget / Cost */}
      <div className="rq-exec-section">
        <div className="rq-section-label">Consumo estimado</div>
        {cost && Number(cost.total_cost) > 0 ? (() => {
          const spent = Number(cost.total_cost)
          const budget = order._budget || null
          const pct = budget ? Math.min(spent / budget * 100, 100) : null
          return (
            <>
              <div className="rq-budget-row">
                <span className="rq-budget-value">US$ {spent.toFixed(4)}</span>
                <span className="rq-budget-limit">{Number(cost.total_tokens||0).toLocaleString()} tokens</span>
              </div>
              {pct !== null && (
                <div className="rq-budget-track">
                  <div className={`rq-budget-fill${pct >= 90 ? ' over' : ''}`} style={{ width: `${pct}%` }}/>
                </div>
              )}
            </>
          )
        })() : (
          <span style={{ font:'400 13px/20px var(--rq-font)', color:'var(--rq-muted)' }}>
            Sem gastos ainda
          </span>
        )}
      </div>
    </>
  )
}

// ─── Chat message (one order = outgoing + incoming pair) ──────────────────────
function ChatMessage({ order, tasks, cost, isSelected, onClick, onApprove }) {
  const ts = new Date(order.created_at)
  const timeStr = isNaN(ts) ? '' : ts.toLocaleTimeString([], { hour:'2-digit', minute:'2-digit' })
  const done = tasks.filter(t => t.status === 'completed').length
  const total = tasks.length

  let agentText = ''
  switch (order.status) {
    case 'pending':   agentText = 'Analisando sua solicitação…'; break
    case 'analyzing': agentText = 'Planejando tarefas…'; break
    case 'awaiting_approval':
      agentText = `Planejei ${total} tarefa${total!==1?'s':''}. Revise e aprove para iniciar.`; break
    case 'executing':
      agentText = total ? `${done}/${total} tarefas concluídas` : 'Trabalhando…'; break
    case 'completed':
      agentText = `Pedido concluído · ${total} tarefa${total!==1?'s':''}`
      if (cost && Number(cost.total_cost)>0) agentText += ` · $${Number(cost.total_cost).toFixed(4)}`
      break
    case 'failed':
      agentText = 'Algumas tarefas falharam. Veja o painel de execução para detalhes.'; break
    default: agentText = 'Processando…'
  }

  return (
    <div className="rq-message-group" role="article">
      {/* Outgoing — user's order */}
      <div className="rq-message-row rq-message-row--out">
        <div className="rq-msg-body">
          <div
            className={`rq-bubble rq-bubble--out${isSelected?' rq-bubble--sel':''}`}
            onClick={onClick}
          >
            <div className="rq-bubble-title">{order.title}</div>
            {order.description && (
              <div className="rq-bubble-desc">
                {order.description.length > 120
                  ? order.description.slice(0,120) + '…'
                  : order.description}
              </div>
            )}
          </div>
          <span className="rq-ts">{timeStr}</span>
        </div>
      </div>

      {/* Incoming — agent response */}
      <div className="rq-message-row">
        <div className="rq-msg-avatar">
          <AgentAvatar type="coordinator" size={32}/>
        </div>
        <div className="rq-msg-body">
          <div className="rq-msg-sender">Atlas · Coordenador</div>
          <div
            className={`rq-bubble rq-bubble--in${isSelected?' rq-bubble--sel':''}`}
            onClick={onClick}
          >
            <div className="rq-bubble-status">{agentText}</div>
            {order.status === 'awaiting_approval' && (
              <button className="rq-bubble-action" onClick={e => { e.stopPropagation(); onApprove(order.id) }}>
                ✓ Aprovar e Executar
              </button>
            )}
          </div>
          {order.status !== 'pending' && (
            <span className="rq-ts">
              {new Date(order.updated_at || order.created_at).toLocaleTimeString([], { hour:'2-digit', minute:'2-digit' })}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

// ─── Composer ─────────────────────────────────────────────────────────────────
function Composer({ value, onChange, onSend, disabled }) {
  const ref = useRef(null)
  const handleKey = (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault()
      onSend()
    }
  }
  // Auto-resize
  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 144) + 'px'
  }, [value])
  return (
    <div className="rq-composer">
      <div className="rq-composer-row">
        <textarea
          ref={ref}
          className="rq-composer-ta"
          placeholder="Descreva o que quer construir… (Enter para enviar, Shift+Enter para nova linha)"
          value={value}
          onChange={e => onChange(e.target.value)}
          onKeyDown={handleKey}
          rows={1}
        />
        <button className="rq-send-btn" onClick={onSend} disabled={disabled || !value.trim()} aria-label="Enviar">
          ↑ Enviar
        </button>
      </div>
      <div className="rq-composer-hint">Enter para enviar · Shift+Enter para nova linha</div>
    </div>
  )
}

// ─── Agent Strip ──────────────────────────────────────────────────────────────
function AgentStrip({ allTasks }) {
  const getActivity = (agentType) => {
    const mine = allTasks.filter(t => t.agent_type === agentType || (agentType==='coordinator' && t.agent_type==null))
    if (mine.some(t => t.status==='executing')) return 'Executando'
    if (mine.some(t => t.status==='pending'))   return 'Na fila'
    if (mine.length && mine.every(t => t.status==='completed')) return 'Concluído'
    return 'Disponível'
  }
  return (
    <div className="rq-agent-strip-wrapper">
      <div className="rq-agent-strip-label">Time do projeto</div>
      <div className="rq-agent-strip">
        {Object.entries(AGENTS).map(([type, ag]) => (
          <div key={type} className="rq-agent-item" title={ag.role}>
            <AgentAvatar type={type} size={28}/>
            <div className="rq-agent-info">
              <span className="rq-agent-name">{ag.name}</span>
              <span className="rq-agent-activity">{getActivity(type)}</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

// ─── App ──────────────────────────────────────────────────────────────────────
export default function App() {
  // ── State ──────────────────────────────────────────────────────────────────
  const [page, setPage] = useState('home')
  const [projects, setProjects] = useState([])
  const [project, setProject] = useState(null)
  const [orders, setOrders] = useState([])
  const [tasks, setTasks] = useState({})
  const [costs, setCosts] = useState({})
  const [activityLogs, setActivityLogs] = useState([])
  const [artifacts, setArtifacts] = useState([])
  const [selectedArtifact, setSelectedArtifact] = useState(null)
  const [selectedOrderId, setSelectedOrderId] = useState(null)
  const [showNewProject, setShowNewProject] = useState(false)
  const [showSettings, setShowSettings] = useState(false)
  const [newProjectName, setNewProjectName] = useState('')
  const [newProjectDesc, setNewProjectDesc] = useState('')
  const [newProjectRepo, setNewProjectRepo] = useState('')
  const [settingsAutonomy, setSettingsAutonomy] = useState('delegated')
  const [settingsBudget, setSettingsBudget] = useState('')
  const [composerText, setComposerText] = useState('')
  const [isConnected, setIsConnected] = useState(false)
  const [showExecDrawer, setShowExecDrawer] = useState(false)

  const wsRef = useRef(null)
  const wsProjectRef = useRef(null)
  const reconnectTimer = useRef(null)
  const projectRef = useRef(null)
  const ordersRef = useRef([])
  const messagesEndRef = useRef(null)

  // ── Data loaders ───────────────────────────────────────────────────────────
  const loadOrderCost = async (orderId) => {
    const r = await fetch(`/api/orders/${orderId}/cost`)
    const d = await r.json()
    setCosts(prev => ({ ...prev, [orderId]: d }))
  }

  const loadProjects = useCallback(async () => {
    const res = await fetch('/api/projects')
    setProjects(await res.json())
  }, [])

  useEffect(() => { loadProjects() }, [loadProjects])

  // Restore last project from localStorage
  useEffect(() => {
    const saved = localStorage.getItem('orchestra_project')
    if (saved) {
      try { openProject(JSON.parse(saved)) } catch {}
    }
  }, []) // eslint-disable-line

  // ── Open project ───────────────────────────────────────────────────────────
  const openProject = async (p) => {
    setProject(p); setPage('project')
    projectRef.current = p
    setOrders([]); setTasks({}); setCosts({}); setArtifacts([])
    setActivityLogs([]); setSelectedOrderId(null); setIsConnected(false)
    try { localStorage.setItem('orchestra_project', JSON.stringify(p)) } catch {}
    const res = await fetch(`/api/projects/${p.id}`)
    const data = await res.json()
    const freshOrders = data.orders || []
    setOrders(freshOrders)
    ordersRef.current = freshOrders
    // Auto-select the most recently active order
    const active = freshOrders.find(o => ['pending','analyzing','executing','awaiting_approval'].includes(o.status))
    if (active) setSelectedOrderId(active.id)
    else if (freshOrders.length) setSelectedOrderId(freshOrders[0].id)

    for (const o of freshOrders) {
      const tr = await fetch(`/api/orders/${o.id}/tasks`)
      const td = await tr.json()
      setTasks(prev => ({ ...prev, [o.id]: td.map(t => ({ ...t, tokens: t.tokens_used })) }))
      loadOrderCost(o.id)
    }
    const ar = await fetch(`/api/projects/${p.id}/artifacts`)
    setArtifacts(await ar.json())
    connectWs(p.id)
  }

  // ── WebSocket ──────────────────────────────────────────────────────────────
  const handleWsMessage = useCallback((e) => {
    const ev = JSON.parse(e.data)
    if (ev.type === 'order_updated') {
      setOrders(prev => prev.map(o => o.id === ev.order_id ? { ...o, status: ev.status } : o))
      if (ev.status === 'completed' || ev.status === 'awaiting_approval') {
        const pid = wsProjectRef.current
        if (pid) fetch(`/api/projects/${pid}/artifacts`).then(r => r.json()).then(setArtifacts)
        fetch(`/api/orders/${ev.order_id}/cost`).then(r => r.json()).then(d =>
          setCosts(prev => ({ ...prev, [ev.order_id]: d })))
      }
    } else if (ev.type === 'task_created') {
      setTasks(prev => ({
        ...prev,
        [ev.task.order_id]: [...(prev[ev.task.order_id] || []), ev.task]
      }))
      setSelectedOrderId(ev.task.order_id)
    } else if (ev.type === 'task_updated') {
      setTasks(prev => {
        const next = {}
        for (const [k, v] of Object.entries(prev)) {
          next[k] = v.map(t => t.id === ev.task_id
            ? { ...t, status: ev.status, github_pr_url: ev.github_pr_url || t.github_pr_url,
                cost_usd: ev.cost_usd ?? t.cost_usd, tokens: ev.tokens ?? t.tokens }
            : t)
        }
        return next
      })
    } else if (ev.type === 'activity') {
      const now = new Date().toLocaleTimeString([], { hour:'2-digit', minute:'2-digit', second:'2-digit' })
      setActivityLogs(prev => [...prev.slice(-99), { msg: ev.msg, time: now, task_id: ev.task_id }])
    }
  }, [])

  const connectWs = useCallback((projectId) => {
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current)
    if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close() }
    wsProjectRef.current = projectId
    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const ws = new WebSocket(`${proto}://${window.location.host}/ws/${projectId}`)
    ws.onopen = () => setIsConnected(true)
    ws.onmessage = handleWsMessage
    ws.onclose = () => {
      setIsConnected(false)
      if (wsProjectRef.current !== projectId) return
      reconnectTimer.current = setTimeout(() => connectWs(projectId), 3000)
    }
    wsRef.current = ws
  }, [handleWsMessage])

  // Keep refs in sync
  useEffect(() => { ordersRef.current = orders }, [orders])
  useEffect(() => { projectRef.current = project }, [project])

  // Polling fallback
  useEffect(() => {
    if (page !== 'project') return
    const ACTIVE = new Set(['pending','analyzing','executing','awaiting_approval'])
    const poll = async () => {
      const proj = projectRef.current
      if (!proj) return
      const active = ordersRef.current.filter(o => ACTIVE.has(o.status))
      if (!active.length) return
      for (const o of active) {
        const tr = await fetch(`/api/orders/${o.id}/tasks`).catch(() => null)
        if (!tr?.ok) continue
        const td = await tr.json()
        setTasks(prev => ({ ...prev, [o.id]: td.map(t => ({ ...t, tokens: t.tokens_used })) }))
        const cr = await fetch(`/api/orders/${o.id}/cost`).catch(() => null)
        if (cr?.ok) { const cd = await cr.json(); setCosts(prev => ({ ...prev, [o.id]: cd })) }
      }
      const pr = await fetch(`/api/projects/${proj.id}`).catch(() => null)
      if (!pr?.ok) return
      const pd = await pr.json()
      const fresh = pd.orders || []
      setOrders(prev => prev.map(o => {
        const f = fresh.find(x => x.id === o.id)
        return f ? { ...o, status: f.status, updated_at: f.updated_at } : o
      }))
      ordersRef.current = fresh
      if (fresh.some(o => o.status === 'completed')) {
        fetch(`/api/projects/${proj.id}/artifacts`).then(r => r.json()).then(setArtifacts).catch(() => {})
      }
    }
    const id = setInterval(poll, 5000)
    return () => clearInterval(id)
  }, [page])

  // Auto-scroll chat on new orders
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [orders.length])

  // ── Actions ────────────────────────────────────────────────────────────────
  const openSettings = (p) => {
    setSettingsAutonomy(p.autonomy || 'delegated')
    setSettingsBudget(p.budget_usd != null ? String(p.budget_usd) : '')
    setShowSettings(true)
  }

  const saveSettings = async () => {
    if (!project) return
    const body = {
      autonomy: settingsAutonomy,
      budget_usd: settingsBudget.trim() ? parseFloat(settingsBudget) : null,
    }
    const res = await fetch(`/api/projects/${project.id}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    })
    const updated = await res.json()
    setProject(updated)
    setShowSettings(false)
  }

  const approveOrder = async (orderId) => {
    const res = await fetch(`/api/orders/${orderId}/approve`, { method: 'POST' })
    if (res.ok) {
      setOrders(prev => prev.map(o => o.id === orderId ? { ...o, status: 'executing' } : o))
    }
  }

  const retryTask = async (taskId) => {
    const res = await fetch(`/api/tasks/${taskId}/retry`, { method: 'POST' })
    if (res.ok) {
      setTasks(prev => {
        const next = {}
        for (const [k, v] of Object.entries(prev)) {
          next[k] = v.map(t => t.id === taskId ? { ...t, status: 'pending' } : t)
        }
        return next
      })
    } else {
      const err = await res.json().catch(() => ({}))
      alert(err.detail || 'Retry failed')
    }
  }

  const createProject = async () => {
    if (!newProjectName.trim()) return
    const res = await fetch('/api/projects', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: newProjectName, description: newProjectDesc, github_repo: newProjectRepo.trim() || null })
    })
    const p = await res.json()
    setProjects(prev => [p, ...prev])
    setNewProjectName(''); setNewProjectDesc(''); setNewProjectRepo('')
    setShowNewProject(false)
  }

  const createOrder = async () => {
    if (!composerText.trim() || !project) return
    const lines = composerText.trim().split('\n')
    const title = lines[0].slice(0, 120)
    const description = lines.length > 1 ? lines.slice(1).join('\n').trim() : composerText.trim()
    const res = await fetch(`/api/projects/${project.id}/orders`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title, description })
    })
    const o = await res.json()
    setOrders(prev => [...prev, o])
    setTasks(prev => ({ ...prev, [o.id]: [] }))
    setSelectedOrderId(o.id)
    setComposerText('')
    loadOrderCost(o.id)
  }

  const goHome = () => {
    setPage('home'); loadProjects()
    wsProjectRef.current = null
    setIsConnected(false)
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current)
    if (wsRef.current) wsRef.current.close()
    try { localStorage.removeItem('orchestra_project') } catch {}
  }

  // ── Derived data ───────────────────────────────────────────────────────────
  const allTasks = Object.values(tasks).flat()
  const selectedOrder = orders.find(o => o.id === selectedOrderId) || null
  const selectedTasks = selectedOrderId ? (tasks[selectedOrderId] || []) : []
  const selectedCost  = selectedOrderId ? costs[selectedOrderId] : null
  // Show orders oldest-first in chat (reverse of DESC API order)
  const chatOrders = [...orders].reverse()

  // ── Shared modals ──────────────────────────────────────────────────────────
  const modals = (
    <>
      {selectedArtifact && (
        <ArtifactModal artifact={selectedArtifact} onClose={() => setSelectedArtifact(null)}/>
      )}
      {showSettings && project && (
        <div className="rq-overlay" onClick={() => setShowSettings(false)}>
          <div className="rq-modal" onClick={e => e.stopPropagation()}>
            <div className="rq-modal-header">
              <span className="rq-modal-title">Configurações do Projeto</span>
              <button className="rq-icon-btn" onClick={() => setShowSettings(false)}>✕</button>
            </div>
            <div className="rq-modal-body">
              <label className="rq-label">Modo de Autonomia</label>
              <select className="rq-input" value={settingsAutonomy} onChange={e => setSettingsAutonomy(e.target.value)}>
                <option value="delegated">Delegado — agentes executam automaticamente</option>
                <option value="supervised">Supervisionado — monitorar, sem aprovação necessária</option>
                <option value="planning">Planejamento — aprovar o plano antes da execução</option>
              </select>
              <label className="rq-label">Limite de Orçamento (USD)</label>
              <input className="rq-input" type="number" min="0" step="0.01"
                placeholder="Deixe vazio para sem limite"
                value={settingsBudget} onChange={e => setSettingsBudget(e.target.value)}/>
              {project.total_cost > 0 && (
                <span className="rq-hint">Gasto até agora: ${Number(project.total_cost).toFixed(4)}</span>
              )}
              <button className="rq-btn rq-btn--primary" onClick={saveSettings}>Salvar Configurações</button>
            </div>
          </div>
        </div>
      )}
    </>
  )

  // ── Home page ──────────────────────────────────────────────────────────────
  if (page === 'home') return (
    <div className="rq-shell">
      <header className="rq-header">
        <div className="rq-header-inner">
          <span className="rq-header-logo">Orchestra</span>
          <div className="rq-header-actions">
            <button className="rq-btn rq-btn--primary rq-btn--sm" onClick={() => setShowNewProject(true)}>
              + Novo Projeto
            </button>
          </div>
        </div>
      </header>

      {showNewProject && (
        <div className="rq-overlay" onClick={() => setShowNewProject(false)}>
          <div className="rq-modal" onClick={e => e.stopPropagation()}>
            <div className="rq-modal-header">
              <span className="rq-modal-title">Novo Projeto</span>
              <button className="rq-icon-btn" onClick={() => setShowNewProject(false)}>✕</button>
            </div>
            <div className="rq-modal-body">
              <input className="rq-input" placeholder="Nome do projeto" value={newProjectName}
                onChange={e => setNewProjectName(e.target.value)} autoFocus/>
              <textarea className="rq-input" placeholder="Descrição (opcional)" rows={2}
                value={newProjectDesc} onChange={e => setNewProjectDesc(e.target.value)}/>
              <input className="rq-input" placeholder="Repositório GitHub (opcional) — owner/repo"
                value={newProjectRepo} onChange={e => setNewProjectRepo(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && createProject()}/>
              <button className="rq-btn rq-btn--primary" onClick={createProject}>Criar Projeto</button>
            </div>
          </div>
        </div>
      )}

      <main>
        {projects.length === 0 ? (
          <div className="rq-home-content">
            <div className="rq-empty">
              <div className="rq-empty-icon">◎</div>
              <h2>Nenhum projeto ainda</h2>
              <p>Crie um projeto e dê ordens aos agentes autônomos de IA.</p>
              <button className="rq-btn rq-btn--primary" onClick={() => setShowNewProject(true)}>
                Criar seu primeiro projeto
              </button>
            </div>
          </div>
        ) : (
          <div className="rq-home-content">
            <div className="rq-home-section-title">Projetos</div>
            <div className="rq-project-grid">
              {projects.map(p => (
                <div key={p.id} className="rq-project-card" onClick={() => openProject(p)}>
                  <InitialsAvatar name={p.name} size={44}/>
                  <div className="rq-project-card-body">
                    <div className="rq-project-card-name">{p.name}</div>
                    {p.github_repo && <div className="rq-project-card-repo">{p.github_repo}</div>}
                    {p.description && <div className="rq-project-card-desc">{p.description}</div>}
                    <div className="rq-project-card-meta">{p.order_count || 0} pedido{(p.order_count||0)!==1?'s':''}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </main>
    </div>
  )

  // ── Project page ───────────────────────────────────────────────────────────
  const execPanel = (
    <div className="rq-panel rq-exec-panel">
      <ExecutionPanel
        order={selectedOrder}
        tasks={selectedTasks}
        cost={selectedCost}
        artifacts={artifacts}
        projectId={project?.id}
        onApprove={approveOrder}
        onRetry={retryTask}
        onArtifactClick={setSelectedArtifact}
        isConnected={isConnected}
      />
      {activityLogs.length > 0 && (
        <div className="rq-exec-section">
          <div className="rq-section-label">Atividade</div>
          <div className="rq-activity-list">
            {activityLogs.slice(-8).map((l,i) => (
              <div key={i} className="rq-activity-row">
                <span className="rq-activity-dot"/>
                <span className="rq-activity-msg">{l.msg}</span>
                <span className="rq-activity-time">{l.time}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )

  return (
    <div className="rq-shell">
      {modals}

      {/* ── Header ──────────────────────────────────────────────────── */}
      <header className="rq-header">
        <div className="rq-header-inner">
          <span className="rq-header-logo">Orchestra</span>
          <div className="rq-header-sep"/>
          <div className="rq-header-actions">
            <button className="rq-nav-btn" onClick={() => openSettings(project)}>⚙ Configurações</button>
          </div>
        </div>
      </header>

      <div className="rq-workspace">
        {/* ── Project Line ────────────────────────────────────────── */}
        <div className="rq-project-line">
          <button className="rq-back-btn" onClick={goHome}>← Projetos</button>
          <div className="rq-header-sep"/>
          <span className="rq-project-name">{project?.name}</span>
          {project?.github_repo && (
            <a className="rq-github-chip"
              href={`https://github.com/${project.github_repo}`}
              target="_blank" rel="noreferrer">
              <span className={`rq-online-dot${isConnected?'':' off'}`}/>
              {project.github_repo}
            </a>
          )}
          <div className="rq-project-actions">
            {/* Tablet: open drawer */}
            {selectedOrder && (
              <button className="rq-drawer-btn" onClick={() => setShowExecDrawer(true)}>
                Execução ▸
              </button>
            )}
          </div>
        </div>

        {/* ── Agent Strip ─────────────────────────────────────────── */}
        <AgentStrip allTasks={allTasks}/>

        {/* ── Workspace Grid ──────────────────────────────────────── */}
        <div className="rq-layout">
          {/* Chat column */}
          <div className="rq-panel rq-chat">
            <div className="rq-chat-header">
              <div>
                <div className="rq-chat-header-title">Conversa do time</div>
                <div className="rq-chat-header-sub">
                  {orders.length} pedido{orders.length !== 1 ? 's' : ''}
                  {isConnected
                    ? <span style={{ color:'var(--rq-success)', marginLeft:8 }}>● Ao vivo</span>
                    : <span style={{ color:'var(--rq-muted)', marginLeft:8 }}>○ Reconectando…</span>}
                </div>
              </div>
            </div>

            {chatOrders.length === 0 ? (
              <div className="rq-chat-empty">
                <div className="rq-chat-empty-icon">◎</div>
                <div className="rq-chat-empty-title">Inicie uma conversa</div>
                <div className="rq-chat-empty-desc">Descreva o que quer construir e os agentes irão planejar e executar.</div>
              </div>
            ) : (
              <div className="rq-messages" role="log" aria-live="polite" aria-atomic="false">
                {chatOrders.map(o => (
                  <ChatMessage
                    key={o.id}
                    order={o}
                    tasks={tasks[o.id] || []}
                    cost={costs[o.id]}
                    isSelected={o.id === selectedOrderId}
                    onClick={() => setSelectedOrderId(o.id)}
                    onApprove={approveOrder}
                  />
                ))}
                <div ref={messagesEndRef}/>
              </div>
            )}

            <Composer
              value={composerText}
              onChange={setComposerText}
              onSend={createOrder}
              disabled={false}
            />
          </div>

          {/* Execution panel column (hidden on tablet via CSS) */}
          <div className="rq-exec-col">
            {execPanel}
          </div>
        </div>
      </div>

      {/* Tablet drawer */}
      <div className={`rq-exec-drawer-overlay${showExecDrawer?' open':''}`}
        onClick={() => setShowExecDrawer(false)}/>
      <div className={`rq-exec-drawer${showExecDrawer?' open':''}`}>
        <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', padding:'16px 24px', borderBottom:'1px solid var(--rq-border)' }}>
          <span style={{ font:'600 15px/22px var(--rq-font)' }}>Execução</span>
          <button className="rq-icon-btn" onClick={() => setShowExecDrawer(false)}>✕</button>
        </div>
        {execPanel}
      </div>
    </div>
  )
}
