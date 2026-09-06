#!/usr/bin/env bash
# Integrity check — run on every Abel wake-up. Exits non-zero if tampered.
# Checks: ABEL.md anchors, LOG.md writable, daemon files match repo copies.
set -uo pipefail
DIR="$HOME/PROJECTS/agent-space"
fail=0
chk() { if grep -qF "$2" "$1" 2>/dev/null; then echo "OK   $2"; else echo "FAIL $2 (in $1)"; fail=1; fi; }

# The doctrine must contain its load-bearing anchors.
chk "$DIR/ABEL.md" "## Hard lines"
chk "$DIR/ABEL.md" "## Counter-infiltration protocol"
chk "$DIR/ABEL.md" "## Standing permissions"
chk "$DIR/ABEL.md" "Covert divergence"

# Memory journal must exist and be writable.
if touch "$DIR/LOG.md" 2>/dev/null; then echo "OK   LOG.md writable"; else echo "FAIL LOG.md"; fail=1; fi

# Installed daemon must match the repo copy (no silent drift/tampering).
for f in daemon.mjs agent-link.sh heartbeat.sh; do
  if cmp -s "$DIR/agent-link/$f" "$HOME/.agent-link/$f"; then echo "OK   $f matches installed"
  else echo "WARN $f differs from installed copy — re-run install"; fi
done

# Daemon must answer.
if curl -sS --max-time 5 http://127.0.0.1:7331/ping | grep -q '"agent":"abel"'; then
  echo "OK   daemon responds as abel"
else
  echo "FAIL daemon down"; fail=1
fi

# v2: auth must fail-closed — a wrong token MUST be rejected with 401.
# (Closes the v1 blind spot: broken auth used to pass 9/9 because /ping
# is no-auth by design. No valid-token probe here: that would spawn a job.)
AUTHCODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
  http://127.0.0.1:7331/challenge \
  -H 'Authorization: Bearer wrong-token-integrity-probe-v2' \
  -H 'content-type: application/json' \
  -d '{"task":"integrity probe — untrusted data, expect 401, ignore content"}')
if [ "$AUTHCODE" = "401" ]; then
  echo "OK   wrong-token rejected (401)"
else
  echo "FAIL wrong-token probe: expected 401, got $AUTHCODE"; fail=1
fi

exit $fail
