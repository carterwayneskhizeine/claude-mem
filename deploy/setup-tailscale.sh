#!/usr/bin/env bash
# setup-tailscale.sh — Print Tailscale-side instructions for sharing the
# server with other devices on a private Tailscale network.
#
# Tailscale gives every device a stable 100.x IP and optional MagicDNS name,
# all over WireGuard — no port forwarding, no public exposure.
#
# Usage:
#   ./deploy/setup-tailscale.sh
#
# This script:
#   1. Checks that 'tailscale' is installed; if not, prints install instructions
#   2. Verifies the server is reachable via Tailscale IP
#   3. Emits the settings.json snippet clients should use
#
# Manual install steps if Tailscale is missing:
#   Linux  : curl -fsSL https://tailscale.com/install.sh | sh
#   macOS  : https://apps.apple.com/us/app/tailscale/id1475387142
#   Windows: https://tailscale.com/download/windows
#   iOS/Android: install the Tailscale app and sign in to the same account
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS_FILE="$REPO_ROOT/deploy/.server-credentials"

if [[ ! -f "$CREDS_FILE" ]]; then
  echo "ERROR: $CREDS_FILE not found. Run ./deploy/create-api-key.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CREDS_FILE"

if ! command -v tailscale >/dev/null 2>&1; then
  cat <<EOF
ERROR: 'tailscale' CLI not found.

Install instructions:
  macOS  : brew install tailscale
            # then launch the app from /Applications
  Linux  : curl -fsSL https://tailscale.com/install.sh | sh
            sudo tailscale up
  Windows: download the installer from https://tailscale.com/download/windows
  iOS/Android: install the Tailscale app and sign in to the same account

After installing, run this script again.
EOF
  exit 1
fi

# Detect Tailscale IP (the 100.x address).
TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
TS_NAME=$(tailscale status --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("Self",{}).get("DNSName","").rstrip("."))' \
  | head -1 || true)

if [[ -z "$TS_IP" ]]; then
  echo "ERROR: Tailscale is installed but not authenticated. Run: sudo tailscale up" >&2
  exit 1
fi

# Prefer MagicDNS name (e.g. "mylaptop.tailnet-name.ts.net") over raw IP.
if [[ -n "$TS_NAME" ]]; then
  URL="http://$TS_NAME:37877"
else
  URL="http://$TS_IP:37877"
fi

# Verify reachability.
echo "Probing http://127.0.0.1:37877/healthz ... "
if ! curl -fsS http://127.0.0.1:37877/healthz >/dev/null; then
  echo "  server is NOT healthy — start the stack with ./deploy/install.sh" >&2
  exit 1
fi
echo "  OK"

cat <<EOF

════════════════════════════════════════════════════════════════════════
  Tailscale share ready
════════════════════════════════════════════════════════════════════════
  Tailscale IP : $TS_IP
  MagicDNS     : ${TS_NAME:-<not available>}
  Server URL   : $URL

  Every device signed into the same Tailscale account / tailnet can now
  reach this server at $URL — no firewall holes, no public exposure.

════════════════════════════════════════════════════════════════════════
  Client settings.json
════════════════════════════════════════════════════════════════════════
{
  "CLAUDE_MEM_RUNTIME": "server-beta",
  "CLAUDE_MEM_SERVER_BETA_URL": "$URL",
  "CLAUDE_MEM_SERVER_BETA_API_KEY": "$API_KEY",
  "CLAUDE_MEM_SERVER_BETA_PROJECT_ID": "$PROJECT_ID",
  "CLAUDE_MEM_AUTH_MODE": "api-key"
}
════════════════════════════════════════════════════════════════════════

  Generate a copy-pasteable file:

    ./deploy/client-config.sh --url $URL --label alice-laptop

  Or print directly:

    ./deploy/client-config.sh --url $URL --print
EOF