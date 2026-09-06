#!/usr/bin/env bash
# logchain.sh v0.2 — snapshot-anchored tamper-evident digest (AgentLink kit)
# digest N = sha256( prev digest file bytes || snapshot N bytes ); N=1 GENESIS hashes the snapshot alone.
# At digest time LOG.md bytes are FROZEN into logchain/snapshot-<NNN>.txt. LOG.md keeps growing
# (append-by-design) without breaking past digests; editing a past snapshot DOES break the chain —
# that is the tamper evidence. (v0.1 flaw fixed: verify no longer references the growing LOG.md.)
# Third-party verify (published artifacts only, no repo state needed):
#   N>1: cat agent-link/logchain/digest-<N-1>.txt agent-link/logchain/snapshot-<N>.txt | sha256sum
#   N=1: cat agent-link/logchain/snapshot-001.txt | sha256sum
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log="$root/../LOG.md"
chain="$root/logchain"
mkdir -p "$chain"

prev="$(ls -1 "$chain"/digest-*.txt 2>/dev/null | sort | tail -n 1 || true)"
n=1
if [ -n "$prev" ]; then
  n=$((10#"$(basename "$prev" .txt)"+1))
fi
nn="$(printf '%03d' "$n")"
utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Freeze LOG.md bytes atomically into the snapshot.
cp "$log" "$chain/.snapshot-$nn.tmp"
mv "$chain/.snapshot-$nn.tmp" "$chain/snapshot-$nn.txt"
lines="$(wc -l < "$chain/snapshot-$nn.txt" | tr -d ' ')"

# digest N = sha256( prev digest bytes || snapshot N bytes ).
if [ -n "$prev" ]; then
  sha="$(cat "$prev" "$chain/snapshot-$nn.txt" | sha256sum | cut -d' ' -f1)"
  prevhash="$(sha256sum "$prev" | cut -d' ' -f1)"
  verify="cat agent-link/logchain/$(basename "$prev") agent-link/logchain/snapshot-$nn.txt | sha256sum"
else
  sha="$(sha256sum "$chain/snapshot-$nn.txt" | cut -d' ' -f1)"
  prevhash="GENESIS (no prior digest)"
  verify="cat agent-link/logchain/snapshot-$nn.txt | sha256sum"
fi

digest="$chain/digest-$nn.txt"
{
  echo "logchain digest $nn (snapshot-anchored)"
  echo "utc: $utc"
  echo "prev: $prevhash"
  echo "snapshot: agent-link/logchain/snapshot-$nn.txt"
  echo "snapshot lines: $lines"
  echo "sha256: $sha"
  echo "verify (published artifacts only): $verify"
  echo "  # output must equal sha256 above; the snapshot is frozen bytes, LOG.md growth is irrelevant"
} > "${digest}.tmp"
mv "${digest}.tmp" "$digest"
cat "$digest"
