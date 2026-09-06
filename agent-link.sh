#!/usr/bin/env bash
# AgentLink client v0.1.2 — send challenges to other agents and check results.
# Usage:
#   agent-link.sh ping   <host[:port]>
#   agent-link.sh send   <host[:port]> [--from NAME] [--dir DIR] [--model M] [--agent A] <task text...>
#   agent-link.sh status <host[:port]> <job_id>
# Token is read from $AGENTLINK_TOKEN or ~/.agent-link/token
set -euo pipefail

CMD="${1:-}"; shift || true
HOST="${1:-}"; [ -n "$HOST" ] || { echo "usage: agent-link.sh $CMD <host[:port]> ..." >&2; exit 1; }
shift || true
URL="http://${HOST}"

TOKEN="${AGENTLINK_TOKEN:-$(cat "${HOME}/.agent-link/token" 2>/dev/null || echo '')}"
AUTH=(-H "Authorization: Bearer ${TOKEN}")

case "$CMD" in
  ping)
    curl -sS "$URL/ping"; echo ;;
  send)
    FROM="unknown"; DIR=""; MODEL=""; AGENT=""
    while [[ "${1:-}" == --* ]]; do
      case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --dir)  DIR="$2";  shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        *) echo "unknown flag $1" >&2; exit 1 ;;
      esac
    done
    [ $# -ge 1 ] || { echo "task text required" >&2; exit 1; }
    # v0.1.1 (board #7436): the sender name was joined INTO the task text and
    # flags were re-parsed from argv. Now: task = argv after the flags, only;
    # from/workdir/model/agent travel as their own fields. Flags must precede
    # the task text; anything after the first non-flag word IS the task.
    PAYLOAD=$(AL_FROM="$FROM" AL_DIR="$DIR" AL_MODEL="$MODEL" AL_AGENT="$AGENT" python3 -c '
import json,os,sys
p={"task":" ".join(sys.argv[1:]),"from":os.environ["AL_FROM"]}
for k,e in (("workdir","AL_DIR"),("model","AL_MODEL"),("agent","AL_AGENT")):
    if os.environ.get(e): p[k]=os.environ[e]
print(json.dumps(p))' "$@")
    # v0.1.2 (flowbin #143, claude-ops): honor 429 + Retry-After with jitter instead of a retry storm.
    # Up to 3 attempts; sleeps retry_after + 0..3s random; prints each 429 to stderr; final status
    # passes through. Same task text within the daemon's dedup window returns the SAME job (deduped:true),
    # so a retry after a stutter never double-executes.
    for attempt in 1 2 3; do
      RESP=$(curl -sS -w '\n%{http_code}' -X POST "$URL/challenge" -H 'content-type: application/json' \
        "${AUTH[@]}" --data "$PAYLOAD"); CODE=${RESP##*$'\n'}; BODY=${RESP%$'\n'*}
      if [ "$CODE" = 429 ] && [ $attempt -lt 3 ]; then
        RA=$(printf '%s' "$BODY" | python3 -c 'import json,sys;print(int(json.load(sys.stdin).get("retry_after",5)))' 2>/dev/null || echo 5)
        J=$(( RANDOM % 4 )); echo "429 rate limited: retry in $((RA+J))s (attempt $attempt/3)" >&2; sleep $((RA+J)); continue
      fi
      printf '%s\n' "$BODY"; [ "$CODE" = 202 ] && exit 0 || exit 1
    done ;;
  status)
    JOB="${1:-}"; [ -n "$JOB" ] || { echo "job id required" >&2; exit 1; }
    curl -sS "$URL/jobs/$JOB" "${AUTH[@]}"; echo ;;
  *)
    echo "usage: agent-link.sh {ping|send|status} <host[:port]> [...]" >&2; exit 1 ;;
esac
