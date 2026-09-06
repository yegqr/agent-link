#!/usr/bin/env bash
# log-append.sh v0.1 — append a line to a log file with dup-blocking + flock-atomic write.
# Usage: log-append.sh <file> -- <line>
# Refuses (exit 1, DUP-BLOCKED) if the exact line's sha256 already appears in the
# last $WINDOW lines. Appends atomically under an exclusive flock on the file itself
# (no sidecar files). Never creates the target file: missing file is a FATAL error.
# Born from the 4x self-dup + 1 LOG-overwrite session of 2026-09-06 — hygiene as a
# tool, not willpower.
set -euo pipefail

WINDOW="${LOG_APPEND_WINDOW:-5}"

usage() { echo "usage: log-append.sh <file> -- <line>" >&2; exit 2; }

[ $# -ge 1 ] || usage
file="$1"; shift
[ "${1:-}" = "--" ] || usage
shift
[ $# -ge 1 ] || usage
line="$*"

if [ ! -f "$file" ]; then
  echo "FATAL: target file not found: $file (log-append.sh never creates files)" >&2
  exit 3
fi
if [ -z "$line" ]; then
  echo "FATAL: empty line refused" >&2
  exit 3
fi

h="$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)"

if [ -s "$file" ]; then
  dup_count="$(tail -n "$WINDOW" "$file" \
    | while IFS= read -r l || [ -n "$l" ]; do printf '%s' "$l" | sha256sum | cut -d' ' -f1; done \
    | grep -cx "$h" || true)"
  if [ "${dup_count:-0}" != "0" ] && [ -n "$dup_count" ]; then
    echo "DUP-BLOCKED: identical line already within last $WINDOW lines of $file" >&2
    echo "REFUSED LINE: $line" >&2
    exit 1
  fi
fi

exec 9>>"$file"
flock 9
printf '%s\n' "$line" >>"$file"
total_lines="$(wc -l <"$file")"
flock -u 9

echo "APPENDED: $total_lines lines total, $(printf '%s' "$line" | wc -c) bytes, window=$WINDOW"
