#!/usr/bin/env bash
# client-config.sh — Print or save the ~/.claude-mem/settings.json a remote
# device needs to talk to the shared server.
#
# Reads deploy/.server-credentials (written by create-api-key.sh).
#
# Usage:
#   ./deploy/client-config.sh --print                # dump to stdout
#   ./deploy/client-config.sh --out path/to/settings.json
#                                                # write to file
#   ./deploy/client-config.sh --label "alice-laptop"
#                                                # write to deploy/clients/alice-laptop.settings.json
#   ./deploy/client-config.sh --url https://mem.example.com
#                                                # override the URL (e.g. when using Cloudflare Tunnel)
#
# After generating, transfer the file to the remote device and place it at:
#   ~/.claude-mem/settings.json
# Then ensure that device's claude-mem plugin is built & installed (see README).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS_FILE="$REPO_ROOT/deploy/.server-credentials"

OUT=""
LABEL=""
PRINT=0
URL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) PRINT=1 ;;
    --out) OUT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --url) URL_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CREDS_FILE" ]]; then
  echo "ERROR: $CREDS_FILE not found. Run ./deploy/create-api-key.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CREDS_FILE"

URL="${URL_OVERRIDE:-$PUBLIC_URL}"

SETTINGS_JSON=$(cat <<EOF
{
  "CLAUDE_MEM_RUNTIME": "server-beta",
  "CLAUDE_MEM_SERVER_BETA_URL": "$URL",
  "CLAUDE_MEM_SERVER_BETA_API_KEY": "$API_KEY",
  "CLAUDE_MEM_SERVER_BETA_PROJECT_ID": "$PROJECT_ID",
  "CLAUDE_MEM_AUTH_MODE": "api-key"
}
EOF
)

if [[ "$PRINT" == "1" || -z "$OUT" && -z "$LABEL" ]]; then
  echo "$SETTINGS_JSON"
  exit 0
fi

if [[ -n "$LABEL" ]]; then
  OUT_DIR="$REPO_ROOT/deploy/clients"
  mkdir -p "$OUT_DIR"
  OUT="$OUT_DIR/$LABEL.settings.json"
fi

echo "$SETTINGS_JSON" > "$OUT"
chmod 600 "$OUT"
echo "Wrote: $OUT"
echo
echo "Transfer to the remote device:"
echo "  scp $OUT other-device:.claude-mem/settings.json"
echo
echo "Then on the remote device:"
echo "  mkdir -p ~/.claude-mem"
echo "  mv settings.json ~/.claude-mem/settings.json"
echo "  chmod 600 ~/.claude-mem/settings.json"