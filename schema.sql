CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS project (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    description TEXT,
    github_repo TEXT,
    notification_email TEXT,
    autonomy    TEXT NOT NULL DEFAULT 'delegated',  -- planning | supervised | delegated
    budget_usd  DECIMAL(10,2),                       -- NULL = unlimited
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
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id       UUID NOT NULL REFERENCES "order"(id) ON DELETE CASCADE,
    project_id     UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    title          TEXT NOT NULL,
    description    TEXT,
    agent_type     TEXT NOT NULL DEFAULT 'developer',
    status         TEXT NOT NULL DEFAULT 'pending',
    result         TEXT,
    github_pr_url  TEXT,
    model          TEXT NOT NULL DEFAULT 'claude-sonnet-4-5',
    sort_order     INTEGER NOT NULL DEFAULT 0,
    depends_on     JSONB NOT NULL DEFAULT '[]',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
    version     INTEGER NOT NULL DEFAULT 1,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS artifact_task_path_version_idx
    ON artifact (task_id, kind, path, version);

CREATE TABLE IF NOT EXISTS notification_delivery (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id     UUID NOT NULL REFERENCES "order"(id) ON DELETE CASCADE,
    channel      TEXT NOT NULL,
    recipient    TEXT NOT NULL,
    order_status TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'pending',
    error        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at      TIMESTAMPTZ,
    UNIQUE (order_id, channel, recipient, order_status)
);
