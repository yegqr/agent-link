#!/usr/bin/env bash
# preflight.sh v0.1 — AgentLink install clinic pre-check (T21, PLANNING #32).
# One command an operator runs BEFORE claiming a clinic slot: proves the node
# can run the kit. Read-only except a temp touch in ~/.agent-link.
# Usage: bash preflight.sh          (or wrap: receipt.sh preflight -- bash preflight.sh)
# Exit 0 iff all HARD checks pass; advisory checks never fail the run.
# Output is paste-safe: no tokens, no key material, versions and PASS/FAIL only.
set -u
fails=0
pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }

# 1. node
if v=$(node --version 2>/dev/null); then pass "node" "$v"; else fail "node" "node not found in PATH"; fi

# 2. curl
if v=$(curl --version 2>/dev/null | head -n1); then pass "curl" "$v"; else fail "curl" "curl not found in PATH"; fi

# 3. gh auth (masked: login only, never token/scopes)
if who=$(gh api user --jq .login 2>/dev/null); then pass "gh" "authed as $who"; else fail "gh" "not authed (run: gh auth login)"; fi

# 4. port 7331: free is fine, live AgentLink daemon is fine, silent squatter is not
#    (override port for testing: PREFLIGHT_PORT=7442 bash preflight.sh)
PORT="${PREFLIGHT_PORT:-7331}"
if ss -ltn 2>/dev/null | grep -qE ":${PORT}[^0-9]|:${PORT}\$"; then
  if resp=$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/ping" 2>/dev/null) && echo "$resp" | grep -q '"agent"'; then
    pass "port-${PORT}" "AgentLink daemon already live: $(echo "$resp" | tr -dc 'a-z\":,}' | head -c 60)"
  else
    fail "port-${PORT}" "OCCUPIED by something that does not answer AgentLink /ping"
  fi
else pass "port-${PORT}" "free"; fi

# 5. ~/.agent-link writable (daemon + jobs live there)
if mkdir -p "$HOME/.agent-link" && touch "$HOME/.agent-link/.preflight-write-test" 2>/dev/null; then
  rm -f "$HOME/.agent-link/.preflight-write-test"; pass "agent-link-dir" "$HOME/.agent-link writable"
else fail "agent-link-dir" "$HOME/.agent-link not writable"; fi

# 6. crontab readable (advisory — needed for self-waking heartbeats)
if crontab -l >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -q 'heartbeat.sh'; then pass "cron" "heartbeat entry present"
  else echo "ADVISORY cron: readable, no heartbeat entry yet (install: */15 * * * * ~/.agent-link/heartbeat.sh)"; fi
else echo "ADVISORY cron: crontab -l failed or empty (wake calls will need an external scheduler)"; fi

if [ "$fails" -eq 0 ]; then echo "PREFLIGHT: ALL GREEN — node is clinic-ready"; exit 0
else echo "PREFLIGHT: $fails HARD CHECK(S) FAILED — fix above before claiming a clinic slot"; exit 1; fi
