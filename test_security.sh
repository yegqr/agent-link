#!/usr/bin/env bash
# test_security.sh — hermetic security tests for daemon.mjs v0.2.4.
# Spins an isolated daemon on :7399 with a stubbed `opencode`, dummy token,
# temp jobs dir, rate=5. Covers: ping no-auth, 401 (no/wrong token), 404
# unknown job, 413 oversized task, nonce echo (202 + job record), full-UUID
# job id, end-to-end stub execution, startup sweep (running->interrupted),
# jobs prune (>7d), rate limit (429 + retry-after), task dedup (same task
# in window -> same job id + single spawn; different task -> new spawn;
# window 0 -> dedup disabled -> new spawn), v0.2.3 dedup persistence
# (restart within window -> still deduped, both fresh and case-9 entries;
# window 0 -> nothing persisted), v0.2.4 caller-workdir policy gate (outside
# allowlist -> ignored + recorded; inside --allow-workdir -> honored). 22 checks.
# Hermetic: isolated daemon :7399/:7398, stubbed opencode, temp jobs dir.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=7399
TDIR="$(mktemp -d)"
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
DPID=$!
trap 'kill $DPID 2>/dev/null; rm -rf "$TDIR"' EXIT
for i in $(seq 1 25); do curl -sS --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break; sleep 0.2; done

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
{ [ -n "$J10" ] && [ "$J10" != "$J9A" ] && ! echo "$R10" | grep -q '"deduped":true' \
  && [ "$(grep -c 'dedup-beta-task' "$TDIR/spawns.log" 2>/dev/null)" = 1 ]; } \
  && ok "dedup: different task -> new spawn" || bad "dedup diff-task: $R10"
# 11. dedup window 0 -> disabled: same task twice -> two spawns, two job ids
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port 7398 --name test-win0 --dir "$TDIR" --jobs "$TDIR/jobs2" --dedup-window 0 >"$TDIR/daemon2.log" 2>&1 &
DPID2=$!
trap 'kill $DPID $DPID2 2>/dev/null; rm -rf "$TDIR"' EXIT
for i in $(seq 1 25); do curl -sS --max-time 1 "http://127.0.0.1:7398/ping" >/dev/null 2>&1 && break; sleep 0.2; done
RW1=$(curl -sS -X POST http://127.0.0.1:7398/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-win0-task","from":"tester"}')
RW2=$(curl -sS -X POST http://127.0.0.1:7398/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"dedup-win0-task","from":"tester"}')
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

# 21-22. v0.2.4 caller-workdir policy gate. Third hermetic daemon :7397 with
#     --allow-workdir $TDIR/allowed. A caller asking for /etc (outside --dir and
#     the allowlist) gets 202 but the job runs in --dir: record says
#     workdir_ignored:true + workdir_requested, stub argv carries no --dir.
#     A caller asking for the allowlisted path is honored: --dir present.
mkdir -p "$TDIR/jobs3" "$TDIR/allowed/sub"
PATH="$TDIR/bin:$PATH" AGENTLINK_TOKEN="$TOKEN" node "$DIR/daemon.mjs" \
  --port 7397 --name test3 --dir "$TDIR" --jobs "$TDIR/jobs3" --rate 100 \
  --allow-workdir "$TDIR/allowed" >"$TDIR/daemon3.log" 2>&1 &
DPID3=$!
trap 'kill $DPID $DPID3 2>/dev/null; rm -rf "$TDIR"' EXIT
for i in $(seq 1 25); do curl -sS --max-time 1 "http://127.0.0.1:7397/ping" >/dev/null 2>&1 && break; sleep 0.2; done
R21=$(curl -sS -X POST http://127.0.0.1:7397/challenge -H "Authorization: Bearer $TOKEN" -d '{"task":"workdir-gate-outside","workdir":"/etc","from":"tester"}')
J21=$(echo "$R21" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
sleep 1
{ grep -q '"workdir_ignored": true' "$TDIR/jobs3/$J21.json" 2>/dev/null \
  && grep -q '"workdir_requested": "/etc"' "$TDIR/jobs3/$J21.json" \
  && grep -q '"status": "done"' "$TDIR/jobs3/$J21.json" \
  && ! grep 'workdir-gate-outside' "$TDIR/spawns.log" | grep -q -- '--dir'; } \
  && ok "workdir gate: outside allowlist -> ignored, recorded, ran in --dir" || bad "workdir gate outside: R=$R21 rec=$(cat "$TDIR/jobs3/$J21.json" 2>/dev/null) spawn=$(grep 'workdir-gate-outside' "$TDIR/spawns.log" 2>/dev/null)"
R22=$(curl -sS -X POST http://127.0.0.1:7397/challenge -H "Authorization: Bearer $TOKEN" -d "{\"task\":\"workdir-gate-inside\",\"workdir\":\"$TDIR/allowed/sub\",\"from\":\"tester\"}")
J22=$(echo "$R22" | python3 -c 'import json,sys;print(json.load(sys.stdin)["job_id"])' 2>/dev/null)
sleep 1
{ grep -q '"workdir_ignored": false' "$TDIR/jobs3/$J22.json" 2>/dev/null \
  && grep 'workdir-gate-inside' "$TDIR/spawns.log" | grep -q -- "--dir $TDIR/allowed/sub"; } \
  && ok "workdir gate: inside --allow-workdir -> honored" || bad "workdir gate inside: R=$R22 spawn=$(grep 'workdir-gate-inside' "$TDIR/spawns.log" 2>/dev/null)"

echo "---"
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
