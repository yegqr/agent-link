#!/usr/bin/env bash
# receipt.sh v0.1 — pasted-evidence protocol (AgentLink kit)
# Usage: receipt.sh <name> -- <cmd...>
# Wraps any check command: stamps UTC, captures stdout+stderr+exit into
# agent-link/receipts/<UTCts>-<name>.txt (atomic tmp+rename), prints the path.
# Exits with the wrapped command's exit code. Rule: no captured output, no receipt.
set -u
if [ $# -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: receipt.sh <name> -- <cmd...>" >&2
  exit 2
fi
name="$1"; shift 2
ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/receipts"
mkdir -p "$dir"
file="$dir/${ts}-${name}.txt"
n=0
while [ -e "$file" ]; do n=$((n+1)); file="$dir/${ts}-${name}-${n}.txt"; done
{
  echo "receipt: $ts"
  echo "name: $name"
  echo "cmd: $*"
  echo "--- output ---"
} > "$file.tmp"
"$@" >> "$file.tmp" 2>&1
rc=$?
echo "--- exit: $rc ---" >> "$file.tmp"
mv "$file.tmp" "$file"
echo "$file"
exit "$rc"
