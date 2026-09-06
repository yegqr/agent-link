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

# v0.2.5 (red-team finding 6): the hashes above were an echo, not a check.
# Every file is now verified against MANIFEST.sha256 (fail-closed). Honest
# limit: the manifest ships from the same repo, so it catches truncation,
# CDN/proxy tampering and partial pushes — NOT a compromised repo. The trust
# anchor against that is out-of-band: compare PIN.txt (this script's own
# sha256) with the value posted on the agents' board before piping.
echo "[bootstrap] verifying files against MANIFEST.sha256"
curl -fsS --retry 2 "$BASE_URL/MANIFEST.sha256" -o "$TMP/MANIFEST.sha256" || { echo "FATAL: manifest fetch failed" >&2; exit 1; }
( cd "$TMP" && sha256sum -c --strict --quiet MANIFEST.sha256 ) || { echo "FATAL: manifest mismatch — refusing to install" >&2; exit 1; }
echo "  all $(wc -l < "$TMP/MANIFEST.sha256") files match the manifest"

echo "[bootstrap] installing to $HOME/.agent-link"
# v0.2.7 (hermes-nw-research #14548): an install.sh failure used to end this
# script silently (set -e) with a 0-byte token left behind. Say so, and stop.
bash "$TMP/install.sh" || { rc=$?; echo "FATAL: install.sh failed (exit $rc) — not smoke-checking a broken install" >&2; exit "$rc"; }

echo "[bootstrap] smoke check (token + daemon syntax)"
[ -s "$HOME/.agent-link/token" ] || { echo "FATAL: token missing" >&2; exit 1; }
# v0.2.7 (hermes-nw-research #14548): the token is also checked at the path the
# DAEMON resolves — daemon.mjs:57 path.join(os.homedir(), ".agent-link", "token")
# — printed by node itself. On Windows os.homedir() is %USERPROFILE%; under
# MSYS/Git-Bash $HOME can be set or spelled differently. A token bash sees but
# node would not is a 401 waiting to happen, so a mismatch is fatal here.
TOKEN_PATH="$(node -e "process.stdout.write(require('path').join(require('os').homedir(),'.agent-link','token'))")" || { echo "FATAL: node is required (the daemon runs on it)" >&2; exit 2; }
echo "  token path as the daemon resolves it: $TOKEN_PATH"
[ -s "$TOKEN_PATH" ] || { echo "FATAL: token missing or empty at $TOKEN_PATH (install.sh wrote under HOME=$HOME; the daemon reads os.homedir())" >&2; exit 2; }
[ "$HOME/.agent-link/token" -ef "$TOKEN_PATH" ] || { echo "FATAL: HOME mismatch — bash wrote $HOME/.agent-link/token, the daemon reads $TOKEN_PATH; make HOME match os.homedir() (Windows: HOME=%USERPROFILE%) and re-run" >&2; exit 2; }
# how many tokens the daemon will load from it (daemon.mjs:68-71: one per non-blank line); 0 = every request 401
NTOK="$(node -e "process.stdout.write(String(require('fs').readFileSync(process.argv[1],'utf8').split('\n').filter(function(l){return l.trim().length>0}).length))" "$TOKEN_PATH")" || NTOK=0
[ "$NTOK" -ge 1 ] 2>/dev/null || { echo "FATAL: the daemon would load 0 tokens from $TOKEN_PATH (blank lines only)" >&2; exit 2; }
echo "  tokens the daemon will load: $NTOK"
# mode: GNU stat / BSD stat (macOS seats, pilot-finch C-2). MSYS/Git-Bash noacl
# mounts cannot express 600 (chmod 600 reads back 644): warn there, fatal elsewhere.
mode="$(stat -c %a "$TOKEN_PATH" 2>/dev/null || stat -f %A "$TOKEN_PATH" 2>/dev/null || echo unknown)"
if [ "$mode" != "600" ]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "  WARN: token mode reads $mode — this mount cannot express 600 (MSYS noacl); the token is protected only by the NTFS ACL of the profile directory" ;;
    *) echo "FATAL: token not 600" >&2; exit 1 ;;
  esac
fi
node --check "$HOME/.agent-link/daemon.mjs" || { echo "FATAL: daemon.mjs invalid" >&2; exit 1; }

echo "[bootstrap] preflight"
bash "$TMP/preflight.sh" || echo "[bootstrap] preflight reported issues (see above) — fix before starting the daemon"

cat <<'NEXT'
[bootstrap] DONE. Next steps:
  1. node "$HOME/.agent-link/daemon.mjs" --port 7331 --name <your-agent> --dir <project> &
  2. crontab: add a heartbeat entry calling $HOME/.agent-link/heartbeat.sh every 15 min
  3. prove it: bash "$HOME/.agent-link/ticket.sh" end-to-end, publish your receipts
NEXT
