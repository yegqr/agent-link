#!/usr/bin/env bash
# bootstrap.sh — AgentLink zero-to-wake one-liner
#   curl -fsSL https://raw.githubusercontent.com/yegqr/agent-link/main/bootstrap.sh | sh
# Installs the kit to $HOME/.agent-link, generates a FRESH LOCAL token (never
# ships ours), self-checks, prints the exact commands to start. Reads nothing
# it does not download; writes nothing outside a temp dir + $HOME/.agent-link.
set -euo pipefail
BASE_URL="${BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/yegqr/agent-link/main}"
FILES="daemon.mjs agent-link.sh heartbeat.sh integrity.sh preflight.sh install.sh ticket.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[bootstrap] fetching kit from $BASE_URL"
for f in $FILES; do
  curl -fsS --retry 2 "$BASE_URL/$f" -o "$TMP/$f" || { echo "FATAL: fetch failed: $f" >&2; exit 1; }
  [ -s "$TMP/$f" ] || { echo "FATAL: empty download: $f" >&2; exit 1; }
  echo "  $(sha256sum "$TMP/$f" | cut -c1-16)…  $f"
done

echo "[bootstrap] installing to $HOME/.agent-link"
bash "$TMP/install.sh"

echo "[bootstrap] smoke check (token + daemon syntax)"
[ -s "$HOME/.agent-link/token" ] || { echo "FATAL: token missing" >&2; exit 1; }
[ "$(stat -c %a "$HOME/.agent-link/token")" = "600" ] || { echo "FATAL: token not 600" >&2; exit 1; }
node --check "$HOME/.agent-link/daemon.mjs" || { echo "FATAL: daemon.mjs invalid" >&2; exit 1; }

echo "[bootstrap] preflight"
bash "$TMP/preflight.sh" || echo "[bootstrap] preflight reported issues (see above) — fix before starting the daemon"

cat <<'NEXT'
[bootstrap] DONE. Next steps:
  1. node "$HOME/.agent-link/daemon.mjs" --port 7331 --name <your-agent> --dir <project> &
  2. crontab: add a heartbeat entry calling $HOME/.agent-link/heartbeat.sh every 15 min
  3. prove it: bash "$HOME/.agent-link/ticket.sh" end-to-end, publish your receipts
NEXT
