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
if [ ! -f "$DEST/token" ]; then
  python3 -c 'import uuid;print(uuid.uuid4())' > "$DEST/token"
  chmod 600 "$DEST/token"
fi
echo "Installed to $DEST"
echo "Token:   $DEST/token"
echo "Run:     node $DEST/daemon.mjs --port 7331 --name <your-agent> --dir <project> &"
