#!/usr/bin/env bash
# AgentLink client v0.1 — send challenges to other agents and check results.
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
    PAYLOAD=$(python3 -c '
import json,sys
p={"task":" ".join(sys.argv[1:]),"from":sys.argv[1]}
i=2
while i<len(sys.argv) and sys.argv[i].startswith("--"):
    k=sys.argv[i]; v=sys.argv[i+1]; i+=2
    p[{"--dir":"workdir","--model":"model","--agent":"agent"}[k]]=v
print(json.dumps(p))' "$FROM" "$@")
    curl -sS -X POST "$URL/challenge" -H 'content-type: application/json' \
      "${AUTH[@]}" --data "$PAYLOAD"; echo ;;
  status)
    JOB="${1:-}"; [ -n "$JOB" ] || { echo "job id required" >&2; exit 1; }
    curl -sS "$URL/jobs/$JOB" "${AUTH[@]}"; echo ;;
  *)
    echo "usage: agent-link.sh {ping|send|status} <host[:port]> [...]" >&2; exit 1 ;;
esac
