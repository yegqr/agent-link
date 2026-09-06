#!/usr/bin/env bash
# manifest.sh — regenerate MANIFEST.sha256 for the files bootstrap.sh installs.
# Run after every kit change, commit the result together with the change.
set -euo pipefail
cd "$(dirname "$0")"
FILES="daemon.mjs agent-link.sh heartbeat.sh integrity.sh preflight.sh install.sh ticket.sh wallet/mkwallet.mjs wallet/balance.sh wallet/signerd.mjs wallet/approve.sh wallet/mcp-server.mjs wallet/swap_quote.mjs wallet/test_wallet.sh"
sha256sum $FILES > MANIFEST.sha256
echo "MANIFEST.sha256: $(wc -l < MANIFEST.sha256) entries"
