#!/usr/bin/env bash
# install.sh — From-source one-shot install of the claude-mem server stack.
#
# Run on the laptop that will host the shared memory server. Assumes:
#   - Docker Engine with Compose plugin (docker compose ...)
#   - Bun >= 1.0 (for the local plugin sync step)
#   - Node >= 20 (for npm run build)
#   - Internet access to npm, docker hub, GitHub
#
# Usage:
#   ./deploy/install.sh                  # install + start
#   ./deploy/install.sh --pull           # git pull before installing
#   ./deploy/install.sh --no-start       # install only, do not run docker compose up
#   ./deploy/install.sh --rebuild        # force docker image rebuild
#
# After install completes, run:
#   ./deploy/create-api-key.sh           # mint the API key clients will use
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PULL=0
START=1
REBUILD=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;;
    --no-start) START=0 ;;
    --rebuild) REBUILD=1 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

# ─── 0. Preflight ─────────────────────────────────────────────────────────────
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command '$1' not found on PATH" >&2
    exit 1
  fi
}
need docker
need git
command -v bun >/dev/null 2>&1 || {
  echo "WARN: 'bun' not found — attempting to install via npm"
  npm install -g bun
}
need node

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' subcommand not available — install Docker Compose v2" >&2
  exit 1
fi

# ─── 1. Source update ─────────────────────────────────────────────────────────
if [[ "$PULL" == "1" ]]; then
  echo "[1/5] git pull"
  git pull --ff-only
else
  echo "[1/5] skipping git pull (use --pull to enable)"
fi

# ─── 2. .env file ─────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[2/5] generating .env from template"
  if [[ -f "$REPO_ROOT/deploy/.env.example" ]]; then
    cp "$REPO_ROOT/deploy/.env.example" "$ENV_FILE"
  else
    cat > "$ENV_FILE" <<'EOF'
POSTGRES_USER=claude_mem
POSTGRES_PASSWORD=
POSTGRES_DB=claude_mem
EOF
  fi
  # Auto-generate a Postgres password if the user left it blank.
  if grep -qE '^POSTGRES_PASSWORD=$' "$ENV_FILE"; then
    PG_PASS="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | xxd -p -c 48)"
    sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG_PASS|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    echo "      generated random POSTGRES_PASSWORD (saved in $ENV_FILE)"
  fi
  chmod 600 "$ENV_FILE"
else
  echo "[2/5] .env already exists — leaving untouched"
fi

# ─── 3. Build plugin artifacts ────────────────────────────────────────────────
echo "[3/5] building plugin bundle (npm run build)"
npm install
npm run build
npm run sync-marketplace

# ─── 4. Docker compose up ─────────────────────────────────────────────────────
echo "[4/5] docker compose build + up"
COMPOSE_ARGS=(up -d)
[[ "$REBUILD" == "1" ]] && COMPOSE_ARGS+=(--build)
docker compose "${COMPOSE_ARGS[@]}" chroma claude-mem-server claude-mem-worker

# ─── 5. Wait for readiness ────────────────────────────────────────────────────
echo "[5/5] waiting for server /healthz"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:37877/healthz >/dev/null 2>&1; then
    echo "      server is healthy at http://127.0.0.1:37877"
    exit 0
  fi
  sleep 2
done

echo "ERROR: server did not become healthy within 120 seconds." >&2
echo "       Inspect with: docker compose logs claude-mem-server" >&2
exit 1