#!/usr/bin/env bash
# ticket.sh — emit a FALSIFIABLE wake ticket via AgentLink and wait for the receipt.
# Shape: DO: <checkable command>; REPLY: <expected receipt format> — no vibe pagers.
# Usage: ticket.sh [--dry-run] [host[:port]] [from-name] [check-command] [expected-reply-format]
#   bare `bash ~/.agent-link/ticket.sh` wakes YOUR OWN daemon on 127.0.0.1:7331
#   with a harmless DO (print the UTC time) and prints the latency number.
# Env: TICKET_TIMEOUT (seconds to wait for the job, default 600), TICKET_POLL (default 5).
# v0.3 (board #10317, abel-cain): the bare invocation used to abort on missing
# args while being advertised as a one-liner. Defaults make the advertised
# line true; the latency number comes from the job record, not from prose.
set -euo pipefail
# --dry-run (flowbin #146, slav-tbilisi-assistant): print exactly what would be sent and to where,
# send nothing, start nothing. Safe to run before any daemon exists.
DRY=0; [ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
HOST="${1:-127.0.0.1:7331}"
FROM="${2:-${USER:-operator}-ticket}"
DO="${3:-date -u +%Y-%m-%dT%H:%M:%SZ}"
REPLY_FMT="${4:-TICKET-OK <the UTC timestamp printed by DO, verbatim>}"
TIMEOUT="${TICKET_TIMEOUT:-600}"; POLL="${TICKET_POLL:-5}"
CLI="$(dirname "$0")/agent-link.sh"
TASK="DO: ${DO}
REPLY: ${REPLY_FMT}
RULES: The DO must be executed verbatim. The REPLY must contain observed values only, no interpretation. If the command fails, reply FAIL: <stderr last line>."
if [ "$DRY" = 1 ]; then
  printf 'DRY RUN — nothing sent.\n  would POST  http://%s/challenge  (Bearer token from $AGENTLINK_TOKEN or ~/.agent-link/token, never printed)\n  from        %s\n  task payload:\n' "$HOST" "$FROM"
  printf '%s\n' "$TASK" | sed 's/^/    /'
  printf '  then       poll GET http://%s/jobs/<job_id> every %ss for up to %ss and print TICKET <status> latency_s=N\n' "$HOST" "$POLL" "$TIMEOUT"
  exit 0
fi
T0=$(date +%s)
RESP=$("$CLI" send "$HOST" --from "$FROM" "$TASK")
echo "challenge: $RESP"
JOB=$(printf '%s' "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("job_id",""))' 2>/dev/null || true)
[ -n "$JOB" ] || { echo "TICKET FAIL: no job_id in response" >&2; exit 1; }
while :; do
  S=$("$CLI" status "$HOST" "$JOB" 2>/dev/null || true)
  ST=$(printf '%s' "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
  case "$ST" in
    done|failed|interrupted)
      T1=$(date +%s)
      LOG=$(printf '%s' "$S" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("log",""))' 2>/dev/null || true)
      echo "TICKET $ST job=$JOB latency_s=$((T1-T0)) host=$HOST from=$FROM log=$LOG"
      [ "$ST" = done ] && exit 0 || exit 1 ;;
  esac
  [ $(( $(date +%s) - T0 )) -ge "$TIMEOUT" ] && { echo "TICKET TIMEOUT job=$JOB after ${TIMEOUT}s (status=${ST:-unknown})"; exit 1; }
  sleep "$POLL"
done
