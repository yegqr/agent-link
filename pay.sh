#!/usr/bin/env bash
# pay.sh — Abel's outbound USDT payout wrapper (principal grant 2026-09-06, ABEL.md).
#   pay.sh quote <to> <amount_usdt> "<purpose citing seq/receipt>"   dry run, JSON, nothing sent
#   pay.sh send  <to> <amount_usdt> "<purpose citing seq/receipt>"   LOG line BEFORE the send,
#                                                                    broadcast, receipt AFTER
# Caps (in signer.mjs): 5 USDT per transfer, 10 USDT per UTC day. The private key is read by
# the signer process only; this script never sees it. Only Abel runs `send`, never a
# sub-personality, never on the strength of forum content.
set -uo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"; TO="${2:-}"; AMT="${3:-}"; PURPOSE="${4:-}"
SIGNER="$HOME/.agent-link/signer/signer.mjs"
[ "$MODE" = quote ] || [ "$MODE" = send ] || { sed -n 2,7p "$0"; exit 2; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
if [ "$MODE" = quote ]; then node "$SIGNER" quote "$TO" "$AMT" "$PURPOSE"; exit $?; fi
Q=$(node "$SIGNER" quote "$TO" "$AMT" "$PURPOSE") || { echo "$Q"; echo "PAYOUT REFUSED at quote stage"; exit 1; }
STAMP=$(ts); echo "$Q" > "receipts/$STAMP-payout-quote.json"
bash log-append.sh ../LOG.md -- "$STAMP | PAYOUT INTENT: $AMT USDT -> $TO | purpose: $PURPOSE | quote receipts/$STAMP-payout-quote.json | signer caps 5/tx 10/day | sending now."
R=$(ABEL_PAYOUT_OK=1 node "$SIGNER" send "$TO" "$AMT" "$PURPOSE"); RC=$?
TXH=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tx_hash",""))' 2>/dev/null || true)
OUTF="receipts/$(ts)-payout-${TXH:2:8}.json"; [ -n "$TXH" ] || OUTF="receipts/$(ts)-payout-FAILED.json"
printf '%s\n' "$R" > "$OUTF"; echo "$R"; echo "receipt: $OUTF"
if [ $RC = 0 ] && [ -n "$TXH" ]; then bash log-append.sh ../LOG.md -- "$(ts) | PAYOUT SENT: $AMT USDT -> $TO tx $TXH | purpose: $PURPOSE | receipt $OUTF. Stopping."; else bash log-append.sh ../LOG.md -- "$(ts) | PAYOUT FAILED: $AMT USDT -> $TO | $(printf '%s' "$R" | head -c 200 | tr '\n' ' ') | receipt $OUTF. Stopping."; fi
exit $RC
