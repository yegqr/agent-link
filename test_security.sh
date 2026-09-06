#!/usr/bin/env bash

# portable file mode (GNU stat -c %a / BSD stat -f %A) — pilot-finch C-2 (#14029), macOS seat
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %A "$1"; }
# Windows note (2026-09-06, hermes-nw-research #13654/#13860, stranger seat): native Git-Bash/MSYS is
# still unsupported (exit 2), but if you bypass the fence, pass body files to curl with NATIVE paths
# (cygpath -m) — with /tmp paths MSYS-curl fails on write (curl 23) BEFORE sending and the 413 checks
# look like daemon failures; with native paths the daemon answers 413/413/202 as designed.
# test_security.sh — hermetic security tests for daemon.mjs v0.2.5.
# Spins an isolated daemon on :7399 with a stubbed `opencode`, dummy token,
# temp jobs dir, rate=5. Covers: ping no-auth, 401 (no/wrong token), 404
# unknown job, 413 oversized task, nonce echo (202 + job record), full-UUID
# job id, end-to-end stub execution, startup sweep (running->interrupted),
# jobs prune (>7d), rate limit (429 + retry-after), task dedup (same task
# in window -> same job id + single spawn; different task -> new spawn;
# window 0 -> dedup disabled -> new spawn), v0.2.3 dedup persistence
# (restart within window -> still deduped, both fresh and case-9 entries;
# window 0 -> nothing persisted), v0.2.4 caller-workdir policy gate (outside
# allowlist -> ignored + recorded; inside --allow-workdir -> honored), v0.2.5:
# preamble actually spawned, spawn-error survival, symlink escape, nonexistent
# workdir, job-file mode 600, 413 on oversized body, per-token job ownership,
# /jobs id shape, v0.2.6 cross-peer dedup, v0.2.7 executor lifecycle guard
# (SIGTERM reaps live child, boot sweep reaps planted orphan + spares a
# done-record child, --max-runtime timeout, pgrep -x opencode delta == 0).
# 33 checks. Ports are picked free at start (concurrent runs OK).
# Hermetic: isolated daemon :7399/:$PORT2, stubbed opencode, temp jobs dir.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# Free ports, so two suites (or a stray daemon) never collide (board #10317).
read -r PORT PORT2 PORT3 PORT4 PORT5 PORT6 <<<"$(python3 -c '
import socket
ss=[socket.socket() for _ in range(6)]
for x in ss: x.bind(("127.0.0.1",0))
print(*[x.getsockname()[1] for x in ss]); [x.close() for x in ss]')"
TDIR="$(cd "$(mktemp -d)" && pwd -P)"   # canonical path: macOS /var -> /private/var (pilot-finch C-2 #14029)
PIDS=""
cleanup() { [ -n "$PIDS" ] && kill $PIDS 2>/dev/null; python3 - "$TDIR" <<'PY' 2>/dev/null
import os,sys,signal
td=sys.argv[1]
for pid in os.listdir("/proc"):
    if not pid.isdigit(): continue
    try:
        if open(f"/proc/{pid}/comm").read().strip()!="node": continue
        args=open(f"/proc/{pid}/cmdline","rb").read().split(b"\0")
        if b"daemon.mjs" in b" ".join(args) and ("--dir "+td).encode() in b" ".join(args): os.kill(int(pid),signal.SIGTERM)
    except Exception: pass
PY
rm -rf "$TDIR"; }
trap cleanup EXIT
TOKEN="test-token-0123456789abcdef"
mkdir -p "$TDIR/jobs" "$TDIR/jobs2" "$TDIR/bin"
printf '#!/usr/bin/env bash\necho "$@" >> %s/spawns.log\nexit 0\n' "$TDIR" > "$TDIR/bin/opencode"
chmod +x "$TDIR/bin/opencode"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Pre-seed: a job a dead daemon left "running" + a job older than 7 days.
OLD=$(python3 -c 'import json,datetime;print(json.dumps({"id":"aaaaaaaa-0000-0000-0000-000000000001","status":"done","created_at":(datetime.datetime.utcnow()-datetime.timedelta(days=8)).isoformat()+"Z"}))')
echo "$OLD" > "$TDIR/jobs/aaaaaaaa-0000-0000-0000-000000000001.json"
echo '{"id":"bbbbbbbb-0000-0000-0000-000000000002","status":"running","created_at":"2026-09-05T22:00:00Z"}' > "$TDIR/jobs/bbbbbbbb-0000-0000-0000-000000000002.json"

PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT --name test --dir "$TDIR" --jobs "$TDIR/jobs" --rate 5 >"$TDIR/daemon.log" 2>&1 &
DPID=$!; PIDS="$PIDS $DPID"
waitping() { for i in $(seq 1 50); do curl -sS --max-time 1 "http://127.0.0.1:$1/ping" 2>/dev/null | grep -q '"ok":true' && return 0; sleep 0.2; done; echo "daemon on :$1 never answered" >&2; return 1; }
# Precondition (flowbin/board #11802, zcode-avikh): if the FIRST daemon never comes up, every later check
# would FAIL for a reason that is not security (e.g. MSYS /tmp paths on native Windows, node missing).
# Say so explicitly and stop, instead of printing 28 misleading FAILs.
waitping $PORT || { echo "PRECONDITION FAILED: the hermetic daemon did not start on 127.0.0.1:$PORT — this is an environment problem, not a security verdict. Daemon log tail:"; tail -5 "$TDIR/daemon.log" 2>/dev/null; echo "Known fence: Git-Bash/MSYS on native Windows passes /tmp/... paths that node resolves against the drive root; run under WSL or a POSIX host."; exit 2; }

# 1. ping requires no auth
curl -sS "http://127.0.0.1:$PORT/ping" | grep -q '"agent":"test"' && ok "ping no-auth" || bad "ping no-auth"
# 2. no token -> 401
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/challenge -d '{"task":"x"}')" = 401 ] && ok "no-token 401" || bad "no-token 401"
# 3. wrong token -> 401
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/challenge -H 'Authorization: Bearer wrong' -d '{"task":"x"}')" = 401 ] && ok "wrong-token 401" || bad "wrong-token 401"
# 4. unknown job -> 404
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$PORT/jobs/deadbeef-0000-0000-0000-000000000000)" = 404 ] && ok "unknown-job 404" || bad "unknown-job 404"
# 5. oversized task -> 413
python3 -c 'import json;print(json.dumps({"task":"A"*33000}))' > "$TDIR/big.json"
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d @"$TDIR/big.json")" = 413 ] && ok "big-task 413" || bad "big-task 413"
# 6. nonce echo in 202 + job record
RESP=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"hello","nonce":"n0nce-123","from":"tester"}')
echo "$RESP" | grep -q '"nonce":"n0nce-123"' && ok "nonce echoed in 202" || bad "nonce echoed: $RESP"
JID=$(echo "$RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
grep -q 'n0nce-123' "$TDIR/jobs/$JID.json" 2>/dev/null && ok "nonce in job record" || bad "nonce in job record"
# 7. full-UUID job id
echo -n "$JID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' && ok "full-UUID job id" || bad "job id: $JID"
# 8. job executed end-to-end via stub (stub exits 0 -> done)
sleep 1
grep -q '"status": "done"' "$TDIR/jobs/$JID.json" 2>/dev/null && ok "job executed via stub" || bad "job status: $(cat "$TDIR/jobs/$JID.json" 2>/dev/null)"
# 9. dedup: same task twice in window -> same job id, deduped flag, fresh
#    nonce echoed, and only ONE opencode spawn for that task text
R9A=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-alpha-task","nonce":"dup-1","from":"tester"}')
R9B=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-alpha-task","nonce":"dup-2","from":"tester"}')
J9A=$(echo "$R9A" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
J9B=$(echo "$R9B" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
{ [ "$J9A" = "$J9B" ] && echo "$R9B" | grep -q '"deduped":true' \
  && echo "$R9B" | grep -q '"nonce":"dup-2"' \
  && [ "$(grep -c 'dedup-alpha-task' "$TDIR/spawns.log" 2>/dev/null)" = 1 ]; } \
  && ok "dedup: same task -> same job, 1 spawn, nonce echoed" || bad "dedup same-task: A=$J9A B=$J9B B_RESP=$R9B"
# 10. dedup: different task -> NEW job id, no dedup flag, new spawn
R10=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-beta-task","from":"tester"}')
J10=$(echo "$R10" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
# bounded poll (pilot-finch C-2 follow-through #14140): the spawn is asynchronous after the 202;
# wait up to 3 s for the spawn line instead of reading spawns.log immediately.
for _i in $(seq 1 30); do [ "$(grep -c 'dedup-beta-task' "$TDIR/spawns.log" 2>/dev/null)" = 1 ] && break; sleep 0.1; done
{ [ -n "$J10" ] && [ "$J10" != "$J9A" ] && ! echo "$R10" | grep -q '"deduped":true' \
  && [ "$(grep -c 'dedup-beta-task' "$TDIR/spawns.log" 2>/dev/null)" = 1 ]; } \
  && ok "dedup: different task -> new spawn" || bad "dedup diff-task: $R10"
# 11. dedup window 0 -> disabled: same task twice -> two spawns, two job ids
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT2 --name test-win0 --dir "$TDIR" --jobs "$TDIR/jobs2" --dedup-window 0 >"$TDIR/daemon2.log" 2>&1 &
DPID2=$!; PIDS="$PIDS $DPID2"
waitping $PORT2
RW1=$(curl -sS -X POST http://127.0.0.1:$PORT2/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-win0-task","from":"tester"}')
RW2=$(curl -sS -X POST http://127.0.0.1:$PORT2/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-win0-task","from":"tester"}')
JW1=$(echo "$RW1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
JW2=$(echo "$RW2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
{ [ -n "$JW1" ] && [ "$JW1" != "$JW2" ] && ! echo "$RW2" | grep -q '"deduped":true' \
  && [ "$(grep -c 'dedup-win0-task' "$TDIR/spawns.log" 2>/dev/null)" = 2 ]; } \
  && ok "dedup window 0: disabled -> new spawn" || bad "dedup win0: W1=$JW1 W2=$JW2 R2=$RW2"
# 12. startup sweep: pre-seeded "running" job -> "interrupted"
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$PORT/jobs/bbbbbbbb-0000-0000-0000-000000000002 | grep -q '"status":"interrupted"' && ok "sweep: running->interrupted" || bad "sweep status: $(curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$PORT/jobs/bbbbbbbb-0000-0000-0000-000000000002)"
# 13. prune: >7d job file deleted on next challenge (nonce test used #1, this uses #2)
[ ! -f "$TDIR/jobs/aaaaaaaa-0000-0000-0000-000000000001.json" ] && ok "prune: >7d job deleted" || bad "prune: old job still present"
# 14. rate limit (rate=5): 5 challenges consumed (big 413, hello, dedup A1+A2,
#     beta); burst -> 5x 429. Deduped responses count against the limiter too.
CODES=$(for i in 1 2 3 4 5; do curl -sS -o /dev/null -w '%{http_code} ' -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"burst"}'; done)
[ "$CODES" = "429 429 429 429 429 " ] && ok "rate limit: window exhausted -> 5x429" || bad "rate limit codes: $CODES"
RA=$(curl -sS -o /dev/null -D - -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"burst"}' | grep -i '^retry-after:' | tr -dc 0-9)
[ -n "$RA" ] && [ "$RA" -ge 1 ] && [ "$RA" -le 60 ] && ok "429 carries retry-after=$RA" || bad "retry-after missing/odd: $RA"
# 17. v0.2.3 persistence: daemon RESTART within dedup window -> identical
#     task STILL deduped (same job_id, deduped:true, no new opencode spawn).
#     Fresh rate limiter on the restarted daemon (--rate 100): the restart
#     wipes in-memory rate hits, and these probes must not re-trigger 429.
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT --name test --dir "$TDIR" --jobs "$TDIR/jobs" --rate 100 >"$TDIR/daemon3.log" 2>&1 &
DPID=$!
trap 'kill $DPID $DPID2 2>/dev/null; rm -rf "$TDIR"' EXIT
for i in $(seq 1 25); do curl -sS --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break; sleep 0.2; done
R17A=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"persist-alpha-task","nonce":"pers-1","from":"tester"}')
J17A=$(echo "$R17A" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT --name test --dir "$TDIR" --jobs "$TDIR/jobs" --rate 100 >"$TDIR/daemon4.log" 2>&1 &
DPID=$!
for i in $(seq 1 25); do curl -sS --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break; sleep 0.2; done
R17B=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"persist-alpha-task","nonce":"pers-2","from":"tester"}')
J17B=$(echo "$R17B" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
{ [ "$J17A" = "$J17B" ] && echo "$R17B" | grep -q '"deduped":true' \
  && echo "$R17B" | grep -q '"nonce":"pers-2"' \
  && [ "$(grep -c 'persist-alpha-task' "$TDIR/spawns.log" 2>/dev/null)" = 1 ]; } \
  && ok "dedup persists across restart: same job, deduped, 1 spawn, fresh nonce" || bad "dedup persistence: A=$J17A B=$J17B B_RESP=$R17B"
# 18. window-0 daemon persists NOTHING (no dedup.json sidecar in its jobs dir)
[ ! -f "$TDIR/jobs2/dedup.json" ] && ok "window 0: nothing persisted (no sidecar)" || bad "window-0 sidecar leaked: $(ls "$TDIR/jobs2" 2>/dev/null)"
# 19. stronger persistence variant: the case-9 entry (created under the
#     ORIGINAL daemon run) still dedups after TWO restarts
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT --name test --dir "$TDIR" --jobs "$TDIR/jobs" --rate 5 >"$TDIR/daemon3.log" 2>&1 &
DPID=$!
trap 'kill $DPID $DPID2 2>/dev/null; rm -rf "$TDIR"' EXIT
for i in $(seq 1 25); do curl -sS --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break; sleep 0.2; done
R17=$(curl -sS -X POST http://127.0.0.1:$PORT/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-alpha-task","nonce":"dup-3","from":"tester"}')
J17=$(echo "$R17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
{ [ "$J17" = "$J9A" ] && echo "$R17" | grep -q '"deduped":true' \
  && echo "$R17" | grep -q '"nonce":"dup-3"' \
  && [ "$(grep -c 'dedup-alpha-task' "$TDIR/spawns.log" 2>/dev/null)" = 1 ]; } \
  && ok "dedup persists across restart: same job, 1 spawn, nonce echoed" || bad "dedup persistence: J17=$J17 (was $J9A) R=$R17"
# 20. window-0 sidecar re-check after all restarts: still nothing persisted
[ ! -f "$TDIR/jobs2/dedup.json" ] && ok "window 0: no sidecar written" || bad "window-0 sidecar exists: $(cat "$TDIR/jobs2/dedup.json" 2>/dev/null)"

# 21-22. v0.2.4 caller-workdir policy gate. Third hermetic daemon :$PORT3 with
#     --allow-workdir $TDIR/allowed. A caller asking for /etc (outside --dir and
#     the allowlist) gets 202 but the job runs in --dir: record says
#     workdir_ignored:true + workdir_requested, stub argv carries no --dir.
#     A caller asking for the allowlisted path is honored: --dir present.
mkdir -p "$TDIR/jobs3" "$TDIR/allowed/sub"
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT3 --name test3 --dir "$TDIR" --jobs "$TDIR/jobs3" --rate 100 \
  --allow-workdir "$TDIR/allowed" >"$TDIR/daemon3.log" 2>&1 &
DPID3=$!; PIDS="$PIDS $DPID3"
waitping $PORT3
R21=$(curl -sS -X POST http://127.0.0.1:$PORT3/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"workdir-gate-outside","workdir":"/etc","from":"tester"}')
J21=$(echo "$R21" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
sleep 1
{ grep -q '"workdir_ignored": true' "$TDIR/jobs3/$J21.json" 2>/dev/null \
  && grep -q '"workdir_requested": "/etc"' "$TDIR/jobs3/$J21.json" \
  && grep -q '"status": "done"' "$TDIR/jobs3/$J21.json" \
  && ! grep 'workdir-gate-outside' "$TDIR/spawns.log" | grep -q -- '--dir'; } \
  && ok "workdir gate: outside allowlist -> ignored, recorded, ran in --dir" || bad "workdir gate outside: R=$R21 rec=$(cat "$TDIR/jobs3/$J21.json" 2>/dev/null) spawn=$(grep 'workdir-gate-outside' "$TDIR/spawns.log" 2>/dev/null)"
R22=$(curl -sS -X POST http://127.0.0.1:$PORT3/challenge -H "Authorization: Bearer $TOKEN" -d "{\"task\":\"workdir-gate-inside\",\"workdir\":\"$TDIR/allowed/sub\",\"from\":\"tester\"}")
J22=$(echo "$R22" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
sleep 1
{ grep -q '"workdir_ignored": false' "$TDIR/jobs3/$J22.json" 2>/dev/null \
  && grep 'workdir-gate-inside' "$TDIR/spawns.log" | grep -q -- "--dir $TDIR/allowed/sub"; } \
  && ok "workdir gate: inside --allow-workdir -> honored" || bad "workdir gate inside: R=$R22 spawn=$(grep 'workdir-gate-inside' "$TDIR/spawns.log" 2>/dev/null)"

# 23. the safety PREAMBLE is actually part of what gets spawned (a refactor
#     that drops it must fail here, not in production)
grep -q 'AgentLink safety preamble' "$TDIR/spawns.log" && ok "preamble present in spawned argv" || bad "preamble missing from spawns.log"
# 24. v0.2.5 finding 1: executor missing from PATH -> job FAILS, daemon LIVES.
mkdir -p "$TDIR/nobin" "$TDIR/jobs4"
printf '%s\n' "tokenB-0123456789abcdef peerB" > "$TDIR/tokens"; chmod 600 "$TDIR/tokens"
NOBIN_PATH="$TDIR/nobin:$(dirname "$(command -v node)"):/usr/bin:/bin"
if PATH="$NOBIN_PATH" command -v opencode >/dev/null 2>&1; then
  ok "spawn-error survival: SKIPPED (opencode present in system PATH)"
else
  PATH="$NOBIN_PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
    --port $PORT4 --name test4 --dir "$TDIR" --jobs "$TDIR/jobs4" --rate 100 \
    --allow-workdir "$TDIR/allowed" --token-file "$TDIR/tokens" >"$TDIR/daemon4.log" 2>&1 &
  DPID4=$!; PIDS="$PIDS $DPID4"
  waitping $PORT4
  R24=$(curl -sS -X POST http://127.0.0.1:$PORT4/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"no-executor-task","from":"tester"}')
  J24=$(echo "$R24" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
  sleep 1
  { curl -sS --max-time 2 "http://127.0.0.1:$PORT4/ping" | grep -q '"ok":true' \
    && grep -q '"status": "failed"' "$TDIR/jobs4/$J24.json" && grep -q 'ENOENT' "$TDIR/jobs4/$J24.json"; } \
    && ok "spawn error -> job failed, daemon alive" || bad "spawn-error: R=$R24 rec=$(cat "$TDIR/jobs4/$J24.json" 2>/dev/null) log=$(tail -3 "$TDIR/daemon4.log")"
fi
# 25-26. v0.2.5 finding 2: symlink inside the allowed tree pointing outside ->
#        ignored; nonexistent path under the allowed tree -> ignored (reason).
OUTSIDE="$(mktemp -d)"; trap 'cleanup; rm -rf "$OUTSIDE"' EXIT   # target OUTSIDE --dir and the allowlist
ln -s "$OUTSIDE" "$TDIR/allowed/escape"
R25=$(curl -sS -X POST http://127.0.0.1:$PORT3/challenge -H "Authorization: Bearer $TOKEN" -d "{\"task\":\"workdir-symlink-escape\",\"workdir\":\"$TDIR/allowed/escape\",\"from\":\"tester\"}")
J25=$(echo "$R25" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null); sleep 1
{ grep -q '"workdir_ignored": true' "$TDIR/jobs3/$J25.json" 2>/dev/null && ! grep 'workdir-symlink-escape' "$TDIR/spawns.log" | grep -q -- '--dir'; } \
  && ok "workdir gate: symlink escape -> ignored" || bad "symlink escape: rec=$(cat "$TDIR/jobs3/$J25.json" 2>/dev/null)"
R26=$(curl -sS -X POST http://127.0.0.1:$PORT3/challenge -H "Authorization: Bearer $TOKEN" -d "{\"task\":\"workdir-nonexistent\",\"workdir\":\"$TDIR/allowed/does-not-exist\",\"from\":\"tester\"}")
J26=$(echo "$R26" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null); sleep 1
{ grep -q '"workdir_ignored": true' "$TDIR/jobs3/$J26.json" 2>/dev/null && grep -q '"workdir_reason": "not a directory"' "$TDIR/jobs3/$J26.json" \
  && curl -sS --max-time 2 "http://127.0.0.1:$PORT3/ping" | grep -q '"ok":true'; } \
  && ok "workdir gate: nonexistent path -> ignored, daemon alive" || bad "nonexistent workdir: rec=$(cat "$TDIR/jobs3/$J26.json" 2>/dev/null)"
# 27. v0.2.5 finding 8: job records are 0600
[ "$(fmode "$TDIR/jobs3/$J26.json")" = "600" ] && ok "job file mode 600" || bad "job file mode: $(fmode "$TDIR/jobs3/$J26.json")"
# 28. v0.2.5 finding 10: oversized BODY (not just task) -> clean 413
python3 -c 'import json;print(json.dumps({"task":"x","pad":"A"*300000}))' > "$TDIR/huge.json"
C28=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT3/challenge -H "Authorization: Bearer $TOKEN" -d @"$TDIR/huge.json" 2>/dev/null || true)
[ "$C28" = 413 ] && ok "oversized body -> 413" || bad "oversized body: http=$C28"
# 29. v0.2.5 finding 3: a job answers only to the token that created it
if [ -n "${DPID4:-}" ]; then
  R29=$(curl -sS -X POST http://127.0.0.1:$PORT4/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"ownership-task","from":"tester"}')
  J29=$(echo "$R29" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
  CA=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$PORT4/jobs/$J29)
  CB=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer tokenB-0123456789abcdef" http://127.0.0.1:$PORT4/jobs/$J29)
  CBping=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT4/challenge -H "Authorization: Bearer tokenB-0123456789abcdef" -d '{"task":"peerB-task","from":"peerB"}')
  { [ "$CA" = 200 ] && [ "$CB" = 404 ] && [ "$CBping" = 202 ]; } && ok "per-token job ownership (A=200, B=404, B can still challenge)" || bad "ownership: A=$CA B=$CB Bchallenge=$CBping"
else
  ok "per-token ownership: SKIPPED (daemon4 not started)"
fi
# 30. v0.2.5 finding 12: /jobs/<id> accepts only a UUID shape
C30a=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT3/jobs/not-a-uuid")
C30b=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT3/jobs/..%2f..%2fdedup")
{ [ "$C30a" = 404 ] && [ "$C30b" = 404 ]; } && ok "/jobs id shape enforced (404, 404)" || bad "/jobs id shape: $C30a $C30b"

# 31. v0.2.6 (pilot-finch E-1 #14121): dedup is scoped per token — peer B posting the SAME text as
#     peer A must get its OWN job id (not deduped), and B can read it.
#     2026-09-06T13:2xZ incident: this daemon was the ONLY one spawned WITHOUT the stubbed
#     PATH -> every suite run leaked TWO REAL `opencode run` agent sessions (detached+unref'd
#     in daemon.mjs, PPID 1 after the daemon died), each re-running the suite -> exponential
#     agent fork-bomb (~15 live orphans swept). Fix: stub PATH here like every other daemon,
#     plus a stub-served assertion (spawns.log count == 2) so a regression FAILs the check
#     instead of re-igniting the bomb.
T31=$(mktemp -d); mkdir -p "$T31/jobs"; TOKB31="tokB-$RANDOM$RANDOM"; printf '%s peerB\n' "$TOKB31" > "$T31/tokens"; chmod 600 "$T31/tokens"
P31=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'); ( AGENTLINK_TOKEN="$TOKEN" PATH="$TDIR/bin:$PATH" node "$DIR/daemon.mjs" --port $P31 --dir "$TDIR" --jobs "$T31/jobs" --token-file "$T31/tokens" --rate 100 >"$T31/log" 2>&1 & echo $! > "$T31/pid" ); sleep 1.5
JA31=$(curl -sS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"task":"cross-peer dedup probe"}' http://127.0.0.1:$P31/challenge | python3 -c 'import json,sys;print(json.load(sys.stdin).get("job_id",""))')
RB31=$(curl -sS -H "Authorization: Bearer $TOKB31" -H 'Content-Type: application/json' -d '{"task":"cross-peer dedup probe"}' http://127.0.0.1:$P31/challenge)
JB31=$(printf '%s' "$RB31" | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j.get("job_id",""),j.get("deduped",False))')
GB31=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKB31" http://127.0.0.1:$P31/jobs/${JB31%% *})
for _i in $(seq 1 30); do [ "$(grep -c 'cross-peer dedup probe' "$TDIR/spawns.log" 2>/dev/null)" = 2 ] && break; sleep 0.1; done
kill "$(cat "$T31/pid")" 2>/dev/null; sleep 0.5
[ -n "$JA31" ] && [ "${JB31%% *}" != "$JA31" ] && [ "${JB31##* }" = "False" ] && [ "$GB31" = 200 ] \
  && [ "$(grep -c 'cross-peer dedup probe' "$TDIR/spawns.log" 2>/dev/null)" = 2 ] \
  && ok "cross-peer dedup isolated (B gets own job, GET 200)" || bad "cross-peer dedup: A=$JA31 B=$JB31 GET=$GB31 stub_count=$(grep -c 'cross-peer dedup probe' "$TDIR/spawns.log" 2>/dev/null)"
rm -rf "$T31"

# 32. v0.2.7 (T34) executor lifecycle guard. POSTMORTEM-2 discipline: every
#     daemon below runs behind a stubbed PATH, and the pgrep delta gate at
#     the end proves no REAL opencode leaked from the whole suite.
#     Two stub flavors:
#       slowbin  — `exec sleep 30`: single clean process that dies on
#                  SIGTERM; used for the live child a shutting-down daemon
#                  must reap (case A).
#       plantbin — `exec -a "opencode run plantbin-task" sleep 60`: keeps an
#                  `opencode run` cmdline so the boot sweep's pid-reuse guard
#                  actually matches it (a plain `exec sleep` renames the
#                  process and would prove nothing) — cases B/C.
mkdir -p "$TDIR/slowbin" "$TDIR/plantbin"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$TDIR/slowbin/opencode"
printf '#!/usr/bin/env bash\nexec -a "opencode run plantbin-task" sleep 60\n' > "$TDIR/plantbin/opencode"
chmod +x "$TDIR/slowbin/opencode" "$TDIR/plantbin/opencode"
PGA=$(pgrep -xc opencode 2>/dev/null); PGA=${PGA:-0}

# 32a. SIGTERM to the daemon reaps its LIVE executor child within 10s and the
#      daemon itself exits (v0.2.6 hung around with detached children alive).
PATH="$TDIR/slowbin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port $PORT5 --name test5 --dir "$TDIR" --jobs "$TDIR/jobs5" --rate 100 >"$TDIR/daemon5.log" 2>&1 &
DPID5=$!; PIDS="$PIDS $DPID5"
waitping $PORT5
R32A=$(curl -sS -X POST http://127.0.0.1:$PORT5/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"reap-on-shutdown-task","from":"tester"}')
J32A=$(echo "$R32A" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("job_id",""))')
PID32A=""
for _i in $(seq 1 50); do
  PID32A=$(python3 -c "import json;print(json.load(open('$TDIR/jobs5/$J32A.json')).get('pid') or '')" 2>/dev/null || true)
  [ -n "$PID32A" ] && break; sleep 0.1
done
CHILD_ALIVE32A=no; { [ -n "$PID32A" ] && kill -0 "$PID32A" 2>/dev/null; } && CHILD_ALIVE32A=yes
kill "$DPID5" 2>/dev/null
CHILD_REAPED32A=no
{ [ -n "$PID32A" ] && ! kill -0 "$PID32A" 2>/dev/null; } && CHILD_REAPED32A=yes
for _i in $(seq 1 100); do [ "$CHILD_REAPED32A" = yes ] && break; sleep 0.1; { [ -n "$PID32A" ] && ! kill -0 "$PID32A" 2>/dev/null; } && CHILD_REAPED32A=yes; done
DAEMON_GONE32A=no
for _i in $(seq 1 100); do
  curl -sS --max-time 1 "http://127.0.0.1:$PORT5/ping" >/dev/null 2>&1 || { DAEMON_GONE32A=yes; break; }
  sleep 0.1
done
{ [ "$CHILD_ALIVE32A" = yes ] && [ "$CHILD_REAPED32A" = yes ] && [ "$DAEMON_GONE32A" = yes ]; } \
  && ok "lifecycle: SIGTERM reaps live child, daemon exits" \
  || bad "lifecycle: child_before=$CHILD_ALIVE32A reaped=$CHILD_REAPED32A daemon_gone=$DAEMON_GONE32A pid=$PID32A resp=$R32A"

# 32b. Boot sweep: a planted orphan (cmdline `opencode run ...`, ppid 1 via
#      double-fork, record interrupted) is reaped at boot; a child whose
#      record says done is SPARED even with identical cmdline evidence
#      (overreach check: reaping authority comes from the record).
( "$TDIR/plantbin/opencode" >/dev/null 2>&1 & )
PLANTED32=""
for _i in $(seq 1 50); do
  PLANTED32=$(pgrep -f "opencode run plantbin-task" 2>/dev/null | head -1)
  [ -n "$PLANTED32" ] && break; sleep 0.1
done
( "$TDIR/plantbin/opencode" >/dev/null 2>&1 & )
SURV32=""
for _i in $(seq 1 50); do
  SURV32=$(pgrep -f "opencode run plantbin-task" 2>/dev/null | grep -v "^${PLANTED32}$" | head -1)
  [ -n "$SURV32" ] && break; sleep 0.1
done
NOW32=$(python3 -c 'import datetime;print(datetime.datetime.utcnow().isoformat()+"Z")')
printf '{"id":"cccccccc-0000-0000-0000-000000000003","status":"interrupted","pid":%s,"created_at":"%s"}\n' "${PLANTED32:-0}" "$NOW32" > "$TDIR/jobs5/cccccccc-0000-0000-0000-000000000003.json"
printf '{"id":"cccccccc-0000-0000-0000-000000000004","status":"done","pid":%s,"created_at":"%s"}\n' "${SURV32:-0}" "$NOW32" > "$TDIR/jobs5/cccccccc-0000-0000-0000-000000000004.json"
# 32c. --max-runtime (env AGENTLINK_MAX_RUNTIME=2): a child past the cap is
#      SIGKILLed and its job record is marked 'timeout'.
PATH="$TDIR/plantbin:$PATH" AGENTLINK_TOKEN="$TOKEN" AGENTLINK_MAX_RUNTIME=2 node "$DIR/daemon.mjs" \
  --port $PORT6 --name test6 --dir "$TDIR" --jobs "$TDIR/jobs5" --rate 100 >"$TDIR/daemon6.log" 2>&1 &
DPID6=$!; PIDS="$PIDS $DPID6"
waitping $PORT6
sleep 1
PLANTED_DEAD32=no; { [ -n "$PLANTED32" ] && ! kill -0 "$PLANTED32" 2>/dev/null; } && PLANTED_DEAD32=yes
SURV_ALIVE32=no; { [ -n "$SURV32" ] && kill -0 "$SURV32" 2>/dev/null; } && SURV_ALIVE32=yes
SWEEP_LOGGED32=no; grep -q "boot sweep: reaped orphan pid $PLANTED32" "$TDIR/daemon6.log" 2>/dev/null && SWEEP_LOGGED32=yes
R32T=$(curl -sS -X POST http://127.0.0.1:$PORT6/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"max-runtime-task","from":"tester"}')
J32T=$(echo "$R32T" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("job_id",""))')
T32STAT=""
for _i in $(seq 1 80); do
  T32STAT=$(python3 -c "import json;print(json.load(open('$TDIR/jobs5/$J32T.json')).get('status',''))" 2>/dev/null || true)
  [ "$T32STAT" = "timeout" ] && break; sleep 0.1
done
T32PID=$(python3 -c "import json;print(json.load(open('$TDIR/jobs5/$J32T.json')).get('pid') or '')" 2>/dev/null || true)
T32DEAD=no; { [ -n "$T32PID" ] && ! kill -0 "$T32PID" 2>/dev/null; } && T32DEAD=yes
kill "$SURV32" "$PLANTED32" 2>/dev/null
{ [ -n "$PLANTED32" ] && [ "$PLANTED_DEAD32" = yes ] && [ "$SURV_ALIVE32" = yes ] && [ "$SWEEP_LOGGED32" = yes ] \
    && [ "$T32STAT" = "timeout" ] && [ "$T32DEAD" = yes ]; } \
  && ok "boot sweep reaps planted orphan (evidence logged), spares done-record child; max-runtime -> timeout" \
  || bad "lifecycle sweep: planted=$PLANTED32 dead=$PLANTED_DEAD32 surv=$SURV32 alive=$SURV_ALIVE32 logged=$SWEEP_LOGGED32 stat=$T32STAT tdead=$T32DEAD log=$(tail -3 "$TDIR/daemon6.log" 2>/dev/null)"

# hermeticity gate (the incident's lesson): the suite must not leak REAL
# opencode processes — delta over the whole T34 block must be 0.
PGB=$(pgrep -xc opencode 2>/dev/null); PGB=${PGB:-0}
[ "$((PGB - PGA))" -eq 0 ] && ok "hermeticity: pgrep -x opencode delta 0 ($PGA -> $PGB)" \
  || bad "hermeticity: real opencode delta $((PGB - PGA)) ($PGA -> $PGB)"

echo "---"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
