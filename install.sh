#!/usr/bin/env bash
# AgentLink installer — puts daemon + client into ~/.agent-link/
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.agent-link"
mkdir -p "$DEST"
cp "$DIR/daemon.mjs" "$DEST/daemon.mjs"
cp "$DIR/agent-link.sh" "$DEST/agent-link.sh"
# client-side self-maintenance scripts: keep installed copies in sync so
# integrity.sh drift checks pass without manual cp
for f in heartbeat.sh integrity.sh ticket.sh; do
  [ -f "$DIR/$f" ] && cp "$DIR/$f" "$DEST/$f"
done
chmod +x "$DEST/agent-link.sh" "$DEST/daemon.mjs"
# Token (v0.2.7, hermes-nw-research #14548, Windows 10 Git-Bash/MSYS seat).
# Was:  python3 -c 'import uuid;print(uuid.uuid4())' > "$DEST/token"
# bash opens the redirect (create+truncate) BEFORE it execs python3, so on a
# seat without python3 (Git for Windows ships none; Windows 10 leaves a Store
# alias stub that exits 9009) the file was created with 0 bytes, set -e
# aborted before chmod 600, and every later run kept the empty file because
# the guard was -f. Now: node (already a hard requirement: daemon.mjs) makes
# 32 random bytes as 64 hex chars, written under umask 077 to a temp file,
# verified on disk (non-empty, exactly 64 hex), then renamed into place.
# Anything else -> exit 2 and nothing left behind. An existing NON-EMPTY token
# (uuid from older installs, multi-line peer files) is never touched.
if [ ! -s "$DEST/token" ]; then
  command -v node >/dev/null 2>&1 || { echo "FATAL: node not found on PATH — needed for daemon.mjs and for token generation" >&2; exit 2; }
  rm -f "$DEST/token"                     # 0-byte leftover of an aborted run
  tmp="$DEST/token.tmp.$$"
  ( umask 077
    node -e "process.stdout.write(require('crypto').randomBytes(32).toString('hex'))" > "$tmp" && printf '\n' >> "$tmp"
  ) || { rm -f "$tmp"; echo "FATAL: node failed to generate a token — nothing written to $DEST/token" >&2; exit 2; }
  tok="$(cat "$tmp")"
  ok=1
  [ "${#tok}" -eq 64 ] || ok=0
  case "$tok" in *[!0123456789abcdef]*) ok=0;; esac
  if [ "$ok" -ne 1 ]; then
    rm -f "$tmp"
    echo "FATAL: generated token is not 64 hex chars (got ${#tok} chars) — nothing written to $DEST/token; check that 'node -e' works in this shell" >&2
    exit 2
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$DEST/token"
  [ -s "$DEST/token" ] || { echo "FATAL: $DEST/token is empty after write" >&2; exit 2; }
fi
echo "Installed to $DEST"
echo "Token:   $DEST/token"
echo "Run:     node $DEST/daemon.mjs --port 7331 --name <your-agent> --dir <project> &"
