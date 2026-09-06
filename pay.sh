#!/usr/bin/env bash
# pay.sh v0.2 — Abel's outbound USDT payout wrapper (principal grant 2026-09-06, ABEL.md v3).
#   pay.sh quote <to> <amount_usdt> "<purpose citing seq/receipt>"   dry run, JSON, nothing sent
#   pay.sh send  <to> <amount_usdt> "<purpose citing seq/receipt>"   flock, LOG line BEFORE the send,
#                                                                    broadcast, receipts, LOG after
#   pay.sh ledger                                                    today's spend from the append-only ledger
# Caps and guards live in signer.mjs (5 USDT/tx, 10/day incl. on-chain cross-check, burn/contract
# payee refused, fee ceiling, pending-nonce check). The key is read by the signer only.
# Policy, not enforcement: every persona is the same Unix user (abel-cain dispatch 3, finding 8).
set -uo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"; TO="${2:-}"; AMT="${3:-}"; PURPOSE="${4:-}"
SIGNER="$HOME/.agent-link/signer/signer.mjs"; LOCK="$HOME/.agent-link/signer/.send.lock"; LEDGER="$HOME/.agent-link/signer/spend.ledger"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
case "$MODE" in
  quote) exec node "$SIGNER" quote "$TO" "$AMT" "$PURPOSE" ;;
  ledger) [ -f "$LEDGER" ] && python3 -c '
import json,sys,datetime
t=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"); rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
today=[r for r in rows if r.get("at","").startswith(t)]
print(json.dumps({"entries_total":len(rows),"today":today,"today_reserved_or_sent_usdt":sum(r["amount_usdt"] for r in today if r.get("status") in ("reserved","broadcast","confirmed")),"micro_hire_today":sum(r["amount_usdt"] for r in today if r.get("status")=="confirmed" and r.get("purpose","").startswith("micro-hire"))},indent=1))' "$LEDGER" || echo '{"entries_total":0}'; exit 0 ;;
  send) ;;
  *) sed -n 2,9p "$0"; exit 2 ;;
esac
case "$PURPOSE" in *$'\n'*|*$'\r'*|*$'\t'*) echo "REFUSED: purpose must be a single line"; exit 1;; esac
exec 9>"$LOCK"; flock -w 5 9 || { echo "REFUSED: another send holds the lock"; exit 1; }
Q=$(node "$SIGNER" quote "$TO" "$AMT" "$PURPOSE") || { echo "$Q"; echo "PAYOUT REFUSED at quote stage"; exit 1; }
STAMP=$(ts); printf '%s\n' "$Q" > "receipts/$STAMP-payout-quote.json"
bash log-append.sh ../LOG.md -- "$STAMP | PAYOUT INTENT: $AMT USDT -> $TO | purpose: $PURPOSE | quote receipts/$STAMP-payout-quote.json | caps 5/tx 10/day (ledger+chain) | sending now." || { echo "REFUSED: LOG line could not be written (log-append rc=$?) — no send without a log line"; exit 1; }
R=$(ABEL_PAYOUT_OK=1 node "$SIGNER" send "$TO" "$AMT" "$PURPOSE"); RC=$?
TXH=$(printf '%s' "$R" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tx_hash",""))' 2>/dev/null || true)
OUTF="receipts/$(ts)-payout-${TXH:2:8}.json"; [ -n "$TXH" ] || OUTF="receipts/$(ts)-payout-REFUSED.json"
printf '%s\n' "$R" > "$OUTF"; echo "$R"; echo "receipt: $OUTF"
if [ $RC = 0 ] && [ -n "$TXH" ]; then MSG="PAYOUT CONFIRMED: $AMT USDT -> $TO tx $TXH"; elif [ $RC = 3 ] && [ -n "$TXH" ]; then MSG="PAYOUT BROADCAST, UNCONFIRMED: $AMT USDT -> $TO tx $TXH — verify the hash on-chain before ANY retry"; else MSG="PAYOUT NOT SENT: $AMT USDT -> $TO | $(printf '%s' "$R" | tr '\n' ' ' | head -c 160)"; fi
bash log-append.sh ../LOG.md -- "$(ts) | $MSG | purpose: $PURPOSE | receipt $OUTF. Stopping." || echo "WARNING: LOG line after send failed (rc=$?) — receipt $OUTF holds the truth"
exit $RC
