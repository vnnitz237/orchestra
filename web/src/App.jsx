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
        <div className="task-meta-row">
          {task.model && <span className="task-model">{task.model.replace('claude-','').replace('-4-5','')}</span>}
          {task.cost_usd > 0 && <span className="task-cost">${Number(task.cost_usd).toFixed(4)} · {task.tokens} tokens</span>}
          {task.github_pr_url && (
            <a className="pr-link" href={task.github_pr_url} target="_blank" rel="noreferrer">
              View PR on GitHub
            </a>
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

function OrderCard({ order, tasks, costs, expanded, onExpand }) {
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
  const [costs, setCosts] = useState({})
  const [activityLogs, setActivityLogs] = useState([])
  const [artifacts, setArtifacts] = useState([])
  const [expandedOrders, setExpandedOrders] = useState({})
  const [selectedArtifact, setSelectedArtifact] = useState(null)
  const [showNewProject, setShowNewProject] = useState(false)
  const [showNewOrder, setShowNewOrder] = useState(false)
  const [newProjectName, setNewProjectName] = useState('')
  const [newProjectDesc, setNewProjectDesc] = useState('')
  const [newProjectRepo, setNewProjectRepo] = useState('')
  const [newOrderTitle, setNewOrderTitle] = useState('')
  const [newOrderDesc, setNewOrderDesc] = useState('')
  const wsRef = useRef(null)

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
    setOrders([]); setTasks({}); setCosts({}); setArtifacts({}); setExpandedOrders({}); setActivityLogs([])
    try { localStorage.setItem('orchestra_project', JSON.stringify(p)) } catch {}
    const res = await fetch(`/api/projects/${p.id}`)
    const data = await res.json()
    setOrders(data.orders || [])
    for (const o of data.orders || []) {
      const tr = await fetch(`/api/orders/${o.id}/tasks`)
      const td = await tr.json()
      setTasks(prev => ({ ...prev, [o.id]: td }))
      loadOrderCost(o.id)
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
    }
    wsRef.current = ws
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
          if (wsRef.current) wsRef.current.close()
          try { localStorage.removeItem('orchestra_project') } catch {}
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
            <OrderCard key={o.id} order={o} tasks={tasks} costs={costs}
              expanded={!!expandedOrders[o.id]}
              onExpand={() => setExpandedOrders(prev => ({ ...prev, [o.id]: !prev[o.id] }))} />
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
