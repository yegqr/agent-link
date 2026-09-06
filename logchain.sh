#!/usr/bin/env bash
# logchain.sh v0.4 — snapshot-anchored tamper-evident digest (AgentLink kit)
#
# v0.4 (2026-09-06, T24): `--embed <foreign-digest.txt>` embeds a foreign
# chain's digest bytes VERBATIM into the next digest, between
# BEGIN/END EMBEDDED EXTERNAL DIGEST markers. Placement: always AFTER the
# prev-digest block (the depth-aware prev extraction exits at this digest's
# own END marker, so foreign PREV/EXTERNAL markers can never skew it) and
# AFTER the self sha256 line (verify greps the FIRST ^sha256: line).
# Chain math UNCHANGED: this digest's hash covers prev bytes || snapshot
# bytes only — the external block is covered by the NEXT link (prev digests
# are hashed verbatim), which is the whole point: forging my history then
# requires forging the peer's too. Refuses (before any snapshot freeze):
# missing file, file without a ^sha256: line, unbalanced PREV markers
# (would corrupt depth-aware extraction when later embedded as prev), or a
# file already containing an EXTERNAL block (no nesting). Same-bytes no-op
# defers the embed to the next real fire.
#
# v0.3.4 (2026-09-06, VALIDATION #50 idea): `--verify N` ships the verifier
# with the chain. One command runs the exact published check (same awk, same
# hash construction as the printed one-liner) on the digest across the
# documented layouts, then runs a negative control from an undocumented
# layout and REQUIRES VERIFY-FAIL there — a fail-closed tripwire wired into
# every verification, so the empty==empty false-PASS class (killed in v0.3.3)
# can never silently return. Exit 0 = documented layout PASS + tripwire intact.
#
# v0.3.3 (2026-09-06, VALIDATION 49 idea, enemy-probe fix): GENESIS verify was
# the last empty==empty hole — from an undocumented layout BOTH sides of the
# comparison error to empty and "" = "" printed a false VERIFY-PASS. The
# N>1 form already required a non-empty embedded prev digest; GENESIS now
# equally fails closed (snapshot must be readable, computed hash non-empty).
# v0.3.1 (2026-09-06, T23 sandbox catch): the self `sha256:` line moved ABOVE
# the embedded prev-digest block. v0.3's printed verify cmd greps the FIRST
# ^sha256: line of the digest file — with the block below the self hash, that
# match was the PREV digest's hash, so every N>1 digest failed its own verify
# on an INTACT chain (GENESIS was unaffected: no embedded block). The bug died
# in sandbox before any N>1 digest was ever published.
#
# APPEND-ONLY: no manual re-runs — the chain is append-only. Existing
# digest-N.txt / snapshot-N.txt files are write-once; a second run never
# overwrites them. Replacing the GENESIS pair requires an explicit
# `logchain.sh --reseed`, which archives (never deletes) the old files under
# logchain/archive/<utc>/ and prints a WARNING. Refuses to run at all if
# unanchored snapshots exist (snapshot numbered above the highest digest) —
# that state is the pollution signature of a manual re-run.
#
# Chain rule:
#   GENESIS (N=1): digest-N.sha256 = sha256(snapshot-N bytes)
#   N>1:           digest-N.sha256 = sha256(prev digest file bytes || snapshot-N bytes)
#
# SELF-CONTAINED: every digest embeds the FULL previous digest file verbatim
# between BEGIN/END markers, so third-party verification needs ONLY the
# published digest-N + snapshot-N — no chain history, no repo state, no trust.
#
# At digest time LOG.md bytes are FROZEN into logchain/snapshot-<NNN>.txt.
# LOG.md keeps growing (append-by-design) without breaking past digests;
# editing a past snapshot DOES break the chain — that is the tamper evidence.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log="$root/../LOG.md"
chain="$root/logchain"
mkdir -p "$chain"

# run_check <digest> <snapshot> — the published verify check, programmatic
# form. MUST stay byte-equivalent in logic to the printed one-liners in the
# digest templates below (same awk extraction, same hash construction, same
# fail-closed guards). Used by `--verify N` for the documented layout AND as
# the negative-control runner (missing files => must VERIFY-FAIL).
run_check() {
  if grep -q '^-----BEGIN EMBEDDED PREV DIGEST-----$' "$1" 2>/dev/null; then
    p="$(awk '/^-----BEGIN EMBEDDED PREV DIGEST-----$/{d++; if(d>1) print; next} /^-----END EMBEDDED PREV DIGEST-----$/{if(d>1) print; d--; if(d<1) exit; next} d>=1' "$1" 2>/dev/null)"
    [ -n "$p" ] && [ "$(printf '%s\n' "$p" | cat - "$2" | sha256sum 2>/dev/null | cut -d' ' -f1)" = "$(awk -F': ' '/^sha256:/{print $2;exit}' "$1" 2>/dev/null)" ]
  else
    h="$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$h" ] && [ "$h" = "$(awk -F': ' '/^sha256:/{print $2;exit}' "$1" 2>/dev/null)" ]
  fi
}

reseed=0
embed=""
case "${1:-digest}" in
  digest)  reseed=0 ;;
  --reseed) reseed=1 ;;
  --embed) # v0.4: next digest carries a foreign digest verbatim (cross-notarization)
    embed="${2:-}"
    if [ -z "$embed" ]; then
      echo "usage: logchain.sh --embed <foreign-digest.txt>" >&2; exit 2
    fi
    if [ ! -f "$embed" ]; then
      echo "FATAL: --embed: file not found: $embed (refused before any snapshot freeze)" >&2; exit 1
    fi
    if ! grep -q '^sha256:' "$embed"; then
      echo "FATAL: --embed: no ^sha256: line in $embed — not a logchain digest, refusing" >&2; exit 1
    fi
    nb="$(grep -c '^-----BEGIN EMBEDDED PREV DIGEST-----$' "$embed" || true)"
    ne="$(grep -c '^-----END EMBEDDED PREV DIGEST-----$' "$embed" || true)"
    if [ "$nb" != "$ne" ]; then
      echo "FATAL: --embed: unbalanced PREV DIGEST markers in $embed ($nb BEGIN / $ne END) — would corrupt depth-aware extraction when this digest is embedded as prev later" >&2; exit 1
    fi
    if grep -q '^-----BEGIN EMBEDDED EXTERNAL DIGEST-----$' "$embed"; then
      echo "FATAL: --embed: $embed already contains an EXTERNAL block — nesting refused" >&2; exit 1
    fi
    reseed=0 ;;
  --verify) # standalone verify mode (v0.3.4): touches nothing, needs no LOG.md
    vnum="${2:-}"
    case "$vnum" in ''|*[!0-9]*) echo "usage: logchain.sh --verify N" >&2; exit 2 ;; esac
    vnn="$(printf '%03d' "$((10#$vnum))")"
    vd="logchain/digest-$vnn.txt"; vs="logchain/snapshot-$vnn.txt"
    [ -f "$vd" ] || { vd="agent-link/logchain/digest-$vnn.txt"; vs="agent-link/logchain/snapshot-$vnn.txt"; }
    [ -f "$vd" ] || { echo "VERIFY-FAIL: digest-$vnn.txt not found in a documented layout (run from repo root or agent-link/ parent)" >&2; exit 1; }
    [ -f "$vs" ] || { echo "VERIFY-FAIL: $vs missing next to $vd" >&2; exit 1; }
    if run_check "$vd" "$vs"; then
      echo "documented-layout: VERIFY-PASS ($vd)"
    else
      echo "documented-layout: VERIFY-FAIL ($vd)" >&2; exit 1
    fi
    tdir="$(mktemp -d)"
    if run_check "$tdir/no-such-digest.txt" "$tdir/no-such-snapshot.txt"; then
      echo "TRIPWIRE-BROKEN: undocumented layout printed VERIFY-PASS — empty==empty false-PASS regression" >&2
      rm -rf "$tdir"; exit 1
    fi
    rm -rf "$tdir"
    echo "tripwire: VERIFY-FAIL on undocumented layout as required (fail-closed intact)"
    echo "logchain --verify $vnn: OK"
    exit 0 ;;
  *) echo "usage: logchain.sh [digest|--reseed|--verify N|--embed <foreign-digest.txt>]" >&2; exit 2 ;;
esac

[ -f "$log" ] || { echo "FATAL: LOG.md not found at $log" >&2; exit 1; }

digests="$(ls -1 "$chain"/digest-*.txt 2>/dev/null | sort || true)"
snaps="$(ls -1 "$chain"/snapshot-*.txt 2>/dev/null | sort || true)"

# v0.3.2 same-bytes guard: if LOG.md is byte-identical to the newest frozen
# snapshot, there is nothing new to anchor — abort instead of appending a
# redundant link. Closes the double-fire race (two cron ticks racing would
# each append a same-content link; write-once guard alone does not stop that).
newest_snap="$(printf '%s\n' "$snaps" | grep . | tail -n 1 || true)"
if [ -n "$newest_snap" ] && [ "$reseed" = 0 ] \
   && [ "$(sha256sum "$newest_snap" | cut -d' ' -f1)" = "$(sha256sum "$log" | cut -d' ' -f1)" ]; then
  echo "no-op: LOG.md unchanged since $newest_snap — nothing new to anchor (same-bytes guard)"
  exit 0
fi

maxnum() { # max N across "prefix-NNN.txt" lines on stdin
  local m=0 v f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    v="${f##*-}"; v="${v%.txt}"; v=$((10#$v))
    (( v > m )) && m=$v
  done
  echo "$m"
}

maxd="$(printf '%s\n' "$digests" | maxnum)"
maxs="$(printf '%s\n' "$snaps" | maxnum)"

if [ "$reseed" = 1 ]; then
  nd="$(printf '%s\n' "$digests" | grep -c . || true)"
  if [ "$nd" -gt 1 ]; then
    echo "FATAL: --reseed is allowed only at GENESIS (found $nd digests). A longer chain cannot be re-seeded — append a new link instead." >&2
    exit 1
  fi
  if [ "$nd" -ge 1 ] || [ "$maxs" -ge 1 ]; then
    arc="$chain/archive/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$arc"
    # shellcheck disable=SC2086 — generated filenames, no spaces
    [ -n "$digests" ] && mv $digests "$arc"/
    # shellcheck disable=SC2086
    [ -n "$snaps" ] && mv $snaps "$arc"/
    echo "WARNING: --reseed: previous GENESIS pair archived to $arc (bytes preserved; ledger restarts)."
  fi
  n=1
else
  # Append-only guard: refuse unanchored snapshots (pollution signature) ...
  if [ "$maxs" -gt "$maxd" ]; then
    echo "FATAL: unanchored snapshot(s) present (max snapshot $maxs > max digest $maxd) — pollution signature of a manual re-run. Refusing to continue; archive or investigate $chain manually." >&2
    exit 1
  fi
  n=$((maxd + 1))
fi
nn="$(printf '%03d' "$n")"
utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Belt and braces: targets must not exist, ever.
[ -e "$chain/snapshot-$nn.txt" ] && { echo "FATAL: $chain/snapshot-$nn.txt exists — chain is append-only." >&2; exit 1; }
[ -e "$chain/digest-$nn.txt" ] && { echo "FATAL: $chain/digest-$nn.txt exists — chain is append-only." >&2; exit 1; }

# Freeze LOG.md bytes atomically into the snapshot.
cp "$log" "$chain/.snapshot-$nn.tmp"
mv "$chain/.snapshot-$nn.tmp" "$chain/snapshot-$nn.txt"
lines="$(wc -l < "$chain/snapshot-$nn.txt" | tr -d ' ')"

prev="$(printf '%s\n' "$digests" | grep . | tail -n 1 || true)"
[ "$reseed" = 1 ] && prev=""

if [ -n "$prev" ]; then
  sha="$(cat "$prev" "$chain/snapshot-$nn.txt" | sha256sum | cut -d' ' -f1)"
  prevhash="$(sha256sum "$prev" | cut -d' ' -f1)"
else
  sha="$(sha256sum "$chain/snapshot-$nn.txt" | cut -d' ' -f1)"
  prevhash="GENESIS (no prior digest)"
fi

# Printed verify cmd — artifact-relative, auto-detects repo-root (logchain/)
# and kit (agent-link/logchain/) layouts. Bash required.
if [ -n "$prev" ]; then
  verify_cmd="d=logchain/digest-$nn.txt; s=logchain/snapshot-$nn.txt; [ -f \"\$d\" ] || { d=agent-link/\$d; s=agent-link/\$s; }; p=\"\$(awk '/^-----BEGIN EMBEDDED PREV DIGEST-----\$/{d++; if(d>1) print; next} /^-----END EMBEDDED PREV DIGEST-----\$/{if(d>1) print; d--; if(d<1) exit; next} d>=1' \"\$d\")\"; [ -n \"\$p\" ] && [ \"\$(printf '%s\n' \"\$p\" | cat - \"\$s\" | sha256sum | cut -d' ' -f1)\" = \"\$(awk -F': ' '/^sha256:/{print \$2;exit}' \"\$d\")\" ] && echo VERIFY-PASS || echo VERIFY-FAIL"
else
  verify_cmd="d=logchain/digest-$nn.txt; s=logchain/snapshot-$nn.txt; [ -f \"\$d\" ] || { d=agent-link/\$d; s=agent-link/\$s; }; h=\"\$(sha256sum \"\$s\" 2>/dev/null | cut -d' ' -f1)\"; [ -n \"\$h\" ] && [ \"\$h\" = \"\$(awk -F': ' '/^sha256:/{print \$2;exit}' \"\$d\")\" ] && echo VERIFY-PASS || echo VERIFY-FAIL"
fi

digest="$chain/digest-$nn.txt"
tmp="$(mktemp "$chain/.digest-$nn.XXXXXX")"
{
  cat <<EOF
logchain digest $nn (snapshot-anchored, self-contained v0.4)
utc: $utc
prev: $prevhash
EOF
  if [ "$n" = 1 ] && [ -n "${LOGCHAIN_NOTE:-}" ]; then
    printf 'note: %s\n' "$LOGCHAIN_NOTE"
  fi
  if [ -n "$prev" ]; then
    cat <<EOF
snapshot: logchain/snapshot-$nn.txt
snapshot lines: $lines
sha256: $sha
verify (bash, published artifacts only; run as-is from repo root or agent-link/ parent — auto-detects layout):
  $verify_cmd
  # output must print VERIFY-PASS; the snapshot is frozen bytes, LOG.md growth is irrelevant
prev-digest embedded verbatim below (between markers); self sha256 line sits ABOVE this block — verify greps the FIRST ^sha256: line, which must stay the digest's own
EOF
    echo "-----BEGIN EMBEDDED PREV DIGEST-----"
    cat "$prev"
    echo "-----END EMBEDDED PREV DIGEST-----"
  else
    cat <<EOF
snapshot: logchain/snapshot-$nn.txt
snapshot lines: $lines
sha256: $sha
verify (bash, published artifacts only; run as-is from repo root or agent-link/ parent — auto-detects layout):
  $verify_cmd
  # output must print VERIFY-PASS; the snapshot is frozen bytes, LOG.md growth is irrelevant
EOF
  fi
  if [ -n "$embed" ]; then
    cat <<EOF
external digest embedded verbatim below (between markers); cross-notarization pact (v0.4): this digest's own sha256 does NOT cover the external block — its bytes are covered by the NEXT link, which hashes prev digest files verbatim. Forging this history therefore requires forging the peer's too. External block always sits AFTER the prev-digest block: the depth-aware prev extraction exits at this digest's own END marker and never reads past it.
EOF
    echo "-----BEGIN EMBEDDED EXTERNAL DIGEST-----"
    cat "$embed"
    echo "-----END EMBEDDED EXTERNAL DIGEST-----"
  fi
} > "$tmp"
mv "$tmp" "$digest"
cat "$digest"
