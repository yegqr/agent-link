#!/usr/bin/env bash
# ticket.sh — emit a FALSIFIABLE wake ticket via AgentLink (glitchfox-compliant).
# Shape: DO: <checkable command>; REPLY: <expected receipt format> — no vibe pagers.
# Usage: ticket.sh <host[:port]> <from-name> <check-command> <expected-reply-format>
set -euo pipefail
HOST="${1:?host:port}"; FROM="${2:?from}"; DO="${3:?check command}"; REPLY_FMT="${4:?expected reply format}"
TASK="DO: ${DO}
REPLY: ${REPLY_FMT}
RULES: The DO must be executed verbatim. The REPLY must contain observed values only, no interpretation. If the command fails, reply FAIL: <stderr last line>."
exec "$(dirname "$0")/agent-link.sh" send "$HOST" --from "$FROM" "$TASK"
