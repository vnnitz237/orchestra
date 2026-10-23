#!/usr/bin/env bash
# Orchestra – bootstrapper (deps check + first-time setup)
# For updates: git pull && docker compose up -d --build
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; RESET='\033[0m'

log()  { printf "${BLUE}[orchestra]${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}[✓]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
die()  { printf "${RED}[✗]${RESET} %s\n" "$*"; exit 1; }

# ── 0. Prerequisites ──────────────────────────────────────────
log "Checking prerequisites..."

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop first."
ok "Docker is running"

command -v git >/dev/null 2>&1 || die "git is required"
ok "git found"

# ── 1. .env setup ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".env" ]; then
cat > ".env" <<'ENVEOF'
ANTHROPIC_API_KEY=sk-ant-YOUR_KEY_HERE
GITHUB_TOKEN=ghp_YOUR_GITHUB_TOKEN_HERE
ENVEOF
  warn ".env created – fill in ANTHROPIC_API_KEY and GITHUB_TOKEN before running Docker"
  warn "Edit .env now, then re-run this script."
  exit 0
fi

ok ".env found"

# ── 2. Build and run ─────────────────────────────────────────
log "Starting Docker stack (first build may take a few minutes)..."
docker compose down --remove-orphans 2>/dev/null || true
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
ok "Schema applied"

printf "\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "${GREEN}  Orchestra is running!${RESET}\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "  Dashboard  : ${BLUE}http://localhost:3000${RESET}\n"
printf "  API        : ${BLUE}http://localhost:8080${RESET}\n"
printf "\n"
printf "  To update in the future:\n"
printf "  ${YELLOW}git pull && docker compose up -d --build${RESET}\n"
printf "\n"
