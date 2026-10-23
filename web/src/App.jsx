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
  pending:           { label: 'Pending',           bg: '#f1f1f4', fg: '#6b7280' },
  analyzing:         { label: 'Analyzing',         bg: '#fef3c7', fg: '#d97706' },
  executing:         { label: 'Executing',         bg: '#dbeafe', fg: '#2563eb' },
  completed:         { label: 'Done',              bg: '#d1fae5', fg: '#059669' },
  failed:            { label: 'Failed',            bg: '#fee2e2', fg: '#dc2626' },
  blocked:           { label: 'Blocked',           bg: '#ffedd5', fg: '#ea580c' },
  awaiting_approval: { label: 'Awaiting Approval', bg: '#f3e8ff', fg: '#7c3aed' },
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

function TaskRow({ task, onRetry }) {
  const statusColor = task.status === 'completed' ? '#059669' : task.status === 'executing' ? '#2563eb' : task.status === 'failed' ? '#dc2626' : '#9ca3af'
  const icon = task.status === 'completed' ? '✓' : task.status === 'executing' ? '◌' : task.status === 'failed' ? '✗' : '○'
  return (
    <div className="task-row">
      <div className="task-icon-wrap" style={{ color: statusColor }}>{icon}</div>
      <div className="task-body">
        <div className="task-title">{task.title}</div>
        {task.description && <div className="task-desc">{task.description}</div>}
        <div className="task-meta-row">
          {task.model && <span className="task-model">{task.model.replace('claude-','').replace('-4-5','')}</span>}
          {task.cost_usd > 0 && <span className="task-cost">${Number(task.cost_usd).toFixed(4)} · {task.tokens} tokens</span>}
          {task.github_pr_url && (
            <a className="pr-link" href={task.github_pr_url} target="_blank" rel="noreferrer">
              View PR on GitHub
            </a>
          )}
          {task.status === 'failed' && onRetry && (
            <button className="btn-retry" onClick={() => onRetry(task.id)}>↺ Retry</button>
          )}
        </div>
      </div>
      <Pill status={task.status} />
    </div>
  )
}

function ActivityFeed({ logs }) {
  const endRef = useRef(null)
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }) }, [logs])
  if (!logs.length) return null
  return (
    <div className="activity-feed">
      <div className="panel-title">Activity</div>
      <div className="activity-log">
        {logs.map((l, i) => (
          <div key={i} className="activity-line">
            <span className="activity-dot" />
            <span className="activity-msg">{l.msg}</span>
            <span className="activity-time">{l.time}</span>
          </div>
        ))}
        <div ref={endRef} />
      </div>
    </div>
  )
}

function OrderCard({ order, tasks, costs, expanded, onExpand, onApprove, onRetry }) {
  const taskList = tasks[order.id] || []
  const done = taskList.filter(t => t.status === 'completed').length
  const agentName = 'Coordinator'
  const preview = order.description ? order.description.slice(0, 80) + (order.description.length > 80 ? '...' : '') : ''
  const ts = new Date(order.created_at)
  const timeStr = isNaN(ts) ? '' : ts.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  const cost = costs[order.id]

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
            {cost && cost.total_cost > 0 && (
              <span className="order-cost">${Number(cost.total_cost).toFixed(4)}</span>
            )}
            <Pill status={order.status} />
          </div>
        </div>
      </div>
      {expanded && (
        <div className="order-body">
          <p className="order-desc">{order.description}</p>
          {cost && cost.total_tokens > 0 && (
            <div className="order-cost-detail">
              {cost.total_tokens.toLocaleString()} tokens · ${Number(cost.total_cost).toFixed(4)} · {cost.executions} execution(s)
            </div>
          )}
          {order.status === 'awaiting_approval' && (
            <div className="approve-bar">
              <span className="approve-msg">O coordenador planejou {taskList.length} tarefas. Aprovar execução?</span>
              <button className="btn-approve" onClick={() => onApprove(order.id)}>✓ Aprovar e Executar</button>
            </div>
          )}
          {taskList.length === 0 && order.status === 'pending' && (
            <p className="order-waiting">Waiting for coordinator...</p>
          )}
          {taskList.map(t => <TaskRow key={t.id} task={t} onRetry={onRetry} />)}
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
  const [costs, setCosts] = useState({})
  const [activityLogs, setActivityLogs] = useState([])
  const [artifacts, setArtifacts] = useState([])
  const [expandedOrders, setExpandedOrders] = useState({})
  const [selectedArtifact, setSelectedArtifact] = useState(null)
  const [showNewProject, setShowNewProject] = useState(false)
  const [showNewOrder, setShowNewOrder] = useState(false)
  const [showSettings, setShowSettings] = useState(false)
  const [newProjectName, setNewProjectName] = useState('')
  const [newProjectDesc, setNewProjectDesc] = useState('')
  const [newProjectRepo, setNewProjectRepo] = useState('')
  const [newOrderTitle, setNewOrderTitle] = useState('')
  const [newOrderDesc, setNewOrderDesc] = useState('')
  const [settingsAutonomy, setSettingsAutonomy] = useState('delegated')
  const [settingsBudget, setSettingsBudget] = useState('')
  const wsRef = useRef(null)
  const wsProjectRef = useRef(null)
  const reconnectTimer = useRef(null)
  const projectRef = useRef(null)
  const ordersRef = useRef([])

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

  useEffect(() => {
    const saved = localStorage.getItem('orchestra_project')
    if (saved) {
      try {
        const p = JSON.parse(saved)
        openProject(p)
      } catch {}
    }
  }, [])

  const openProject = async (p) => {
    setProject(p); setPage('project')
    projectRef.current = p
    setOrders([]); setTasks({}); setCosts({}); setArtifacts([]); setExpandedOrders({}); setActivityLogs([])
    try { localStorage.setItem('orchestra_project', JSON.stringify(p)) } catch {}
    const res = await fetch(`/api/projects/${p.id}`)
    const data = await res.json()
    const freshOrders = data.orders || []
    setOrders(freshOrders)
    ordersRef.current = freshOrders
    for (const o of data.orders || []) {
      const tr = await fetch(`/api/orders/${o.id}/tasks`)
      const td = await tr.json()
      setTasks(prev => ({ ...prev, [o.id]: td.map(t => ({ ...t, tokens: t.tokens_used })) }))
      loadOrderCost(o.id)
    }
    const ar = await fetch(`/api/projects/${p.id}/artifacts`)
    setArtifacts(await ar.json())
    connectWs(p.id)
  }

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
      setExpandedOrders(prev => ({ ...prev, [ev.task.order_id]: true }))
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
      const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
      setActivityLogs(prev => [...prev.slice(-99), { msg: ev.msg, time: now, task_id: ev.task_id }])
    }
  }, [])

  const connectWs = useCallback((projectId) => {
    if (reconnectTimer.current) clearTimeout(reconnectTimer.current)
    if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close() }
    wsProjectRef.current = projectId
    const proto = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const ws = new WebSocket(`${proto}://${window.location.host}/ws/${projectId}`)
    ws.onmessage = handleWsMessage
    ws.onclose = () => {
      if (wsProjectRef.current !== projectId) return
      reconnectTimer.current = setTimeout(() => connectWs(projectId), 3000)
    }
    wsRef.current = ws
  }, [handleWsMessage])

  // Keep refs in sync so polling closure always has fresh values
  useEffect(() => { ordersRef.current = orders }, [orders])
  useEffect(() => { projectRef.current = project }, [project])

  // Polling fallback — stable interval, reads state via refs to avoid dep loop
  useEffect(() => {
    if (page !== 'project') return
    const ACTIVE = new Set(['pending', 'analyzing', 'executing', 'awaiting_approval'])
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
      // Merge status updates instead of replacing — preserves React identity of objects
      setOrders(prev => prev.map(o => {
        const f = fresh.find(x => x.id === o.id)
        return f ? { ...o, status: f.status, updated_at: f.updated_at } : o
      }))
      ordersRef.current = fresh
      // Re-fetch artifacts if anything completed
      if (fresh.some(o => o.status === 'completed')) {
        fetch(`/api/projects/${proj.id}/artifacts`).then(r => r.json()).then(setArtifacts).catch(() => {})
      }
    }
    const id = setInterval(poll, 5000)
    return () => clearInterval(id)
  }, [page])  // stable — never recreated while on the project page

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
    setNewProjectName(''); setNewProjectDesc(''); setNewProjectRepo(''); setShowNewProject(false)
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
    loadOrderCost(o.id)
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
                onChange={e => setNewProjectName(e.target.value)} autoFocus />
              <textarea className="input" placeholder="Description (optional)" rows={2}
                value={newProjectDesc} onChange={e => setNewProjectDesc(e.target.value)} />
              <input className="input" placeholder="GitHub repo (optional) — e.g. owner/repo" value={newProjectRepo}
                onChange={e => setNewProjectRepo(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && createProject()} />
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
                  {p.github_repo && <div className="project-card-repo">{p.github_repo}</div>}
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
          wsProjectRef.current = null
          if (reconnectTimer.current) clearTimeout(reconnectTimer.current)
          if (wsRef.current) wsRef.current.close()
          try { localStorage.removeItem('orchestra_project') } catch {}
        }}>← Projects</button>
        <div className="logo">{project?.name}</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn-ghost" onClick={() => openSettings(project)}>⚙ Settings</button>
          <button className="btn-primary" onClick={() => setShowNewOrder(true)}>+ New Order</button>
        </div>
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

      {showSettings && project && (
        <div className="modal-overlay" onClick={() => setShowSettings(false)}>
          <div className="modal" onClick={e => e.stopPropagation()}>
            <div className="modal-header">
              <span className="modal-title">Project Settings</span>
              <button className="btn-icon" onClick={() => setShowSettings(false)}>✕</button>
            </div>
            <div className="form-body">
              <label style={{ fontSize: '0.8125rem', fontWeight: 600 }}>Autonomy Mode</label>
              <select className="input" value={settingsAutonomy} onChange={e => setSettingsAutonomy(e.target.value)}>
                <option value="delegated">Delegated — agents run automatically</option>
                <option value="supervised">Supervised — monitor but no approval needed</option>
                <option value="planning">Planning — approve task plan before execution</option>
              </select>
              <label style={{ fontSize: '0.8125rem', fontWeight: 600 }}>Budget Limit (USD)</label>
              <input className="input" type="number" min="0" step="0.01"
                placeholder="Leave empty for unlimited"
                value={settingsBudget} onChange={e => setSettingsBudget(e.target.value)} />
              {project.total_cost > 0 && (
                <div style={{ fontSize: '0.8rem', color: 'var(--fg2)' }}>
                  Spent so far: ${Number(project.total_cost).toFixed(4)}
                </div>
              )}
              <button className="btn-primary" onClick={saveSettings}>Save Settings</button>
            </div>
          </div>
        </div>
      )}

      <main className="main-content two-col">
        <section className="orders-section">
          {orders.length === 0 ? (
            <div className="empty-state small">
              <p>No orders yet. Tell the agents what to build.</p>
            </div>
          ) : orders.map(o => (
            <OrderCard key={o.id} order={o} tasks={tasks} costs={costs}
              expanded={!!expandedOrders[o.id]}
              onExpand={() => setExpandedOrders(prev => ({ ...prev, [o.id]: !prev[o.id] }))}
              onApprove={approveOrder}
              onRetry={retryTask} />
          ))}
        </section>

        <aside className="right-panel">
          <ActivityFeed logs={activityLogs} />
          {artifacts.length > 0 && (
            <div className="artifacts-panel">
              <div className="panel-title">Generated Files</div>
              {artifacts.map(a => (
                <div key={a.id} className="artifact-row" onClick={() => setSelectedArtifact(a)}>
                  <span className="artifact-icon">📄</span>
                  <span className="artifact-path">{a.path}</span>
                </div>
              ))}
            </div>
          )}
        </aside>
      </main>
    </div>
  )
}
