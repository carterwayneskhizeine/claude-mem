#!/usr/bin/env bash
# create-api-key.sh — Mint a server-beta API key after the stack is up.
#
# Stores the plaintext key + project id + URL in deploy/.server-credentials
# (git-ignored). The plaintext is shown here ONLY — it cannot be recovered
# from the database after this command exits.
#
# Usage:
#   ./deploy/create-api-key.sh                       # one key, default scopes
#   ./deploy/create-api-key.sh --name "alice-laptop" # labelled key
#   ./deploy/create-api-key.sh --scope "memories:read,memories:write"
#   ./deploy/create-api-key.sh --public-url https://mem.example.com
#                                                   # what clients will dial
#                                                   # (defaults to http://<laptop-ip>:37877)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NAME="server-shared-key"
SCOPE="memories:read,memories:write"
PUBLIC_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --public-url) PUBLIC_URL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ─── 1. Server reachable? ─────────────────────────────────────────────────────
if ! curl -fsS http://127.0.0.1:37877/healthz >/dev/null 2>&1; then
  echo "ERROR: server is not reachable at http://127.0.0.1:37877/healthz" >&2
  echo "       Run ./deploy/install.sh first, or 'docker compose up -d'." >&2
  exit 1
fi

# ─── 2. Run the key-create CLI inside the server container ────────────────────
KEY_JSON="$(docker compose exec -T claude-mem-server \
  bun /opt/claude-mem/scripts/server-beta-service.cjs \
    server api-key create \
    --name "$NAME" \
    --scope "$SCOPE")"

if [[ -z "$KEY_JSON" ]]; then
  echo "ERROR: empty response from server" >&2
  exit 1
fi

# Validate the response is JSON.
echo "$KEY_JSON" | python3 -c 'import sys,json; json.loads(sys.stdin.read())' >/dev/null

KEY_ID=$(echo "$KEY_JSON" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["id"])')
RAW_KEY=$(echo "$KEY_JSON" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["key"])')
TEAM_ID=$(echo "$KEY_JSON" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["teamId"])')
PROJECT_ID=$(echo "$KEY_JSON" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["projectId"])')

if [[ -z "$RAW_KEY" || "$RAW_KEY" == "None" ]]; then
  echo "ERROR: server returned no plaintext key" >&2
  echo "$KEY_JSON" >&2
  exit 1
fi

# ─── 3. Determine the URL clients should use ─────────────────────────────────
if [[ -z "$PUBLIC_URL" ]]; then
  # Best guess: the laptop's primary LAN IP, or localhost as fallback.
  DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$DETECTED_IP" ]]; then
    PUBLIC_URL="http://$DETECTED_IP:37877"
  else
    PUBLIC_URL="http://127.0.0.1:37877"
  fi
fi

# ─── 4. Persist to .server-credentials ────────────────────────────────────────
CREDS_FILE="$REPO_ROOT/deploy/.server-credentials"
cat > "$CREDS_FILE" <<EOF
# Generated $(date -Iseconds 2>/dev/null || date)
# This file contains a PLAINTEXT API key. Treat it like a password.
# Do NOT commit this file — it is in .gitignore.

API_KEY_ID=$KEY_ID
API_KEY=$RAW_KEY
TEAM_ID=$TEAM_ID
PROJECT_ID=$PROJECT_ID
PUBLIC_URL=$PUBLIC_URL
SCOPES=$SCOPE
EOF
chmod 600 "$CREDS_FILE"

# ─── 5. Echo the client config snippet (redacted for the terminal) ───────────
cat <<EOF

════════════════════════════════════════════════════════════════════════
  Created server API key
════════════════════════════════════════════════════════════════════════
  Key ID     : $KEY_ID
  Team       : $TEAM_ID
  Project    : $PROJECT_ID
  Scopes     : $SCOPE
  Public URL : $PUBLIC_URL
════════════════════════════════════════════════════════════════════════
  Plaintext key (only shown ONCE — saved in $CREDS_FILE):

  $RAW_KEY

════════════════════════════════════════════════════════════════════════

Next step — register a remote device:

  ./deploy/client-config.sh --label "alice-laptop"

Or print the settings.json directly:

  ./deploy/client-config.sh --print

EOF