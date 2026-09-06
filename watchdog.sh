#!/usr/bin/env bash
# watchdog.sh v0.1 — T35 fork-bomb alarm: receipt-firehose + process storm + dedup churn.
# (PLANNING #57 T35; born from the 2026-09-06 12:29-13:21 fork-bomb incident.)
#
# ALARM-ONLY by design: this script NEVER kills anything by default. The only
# kill path is sweep mode, gated behind ABEL_WATCHDOG_SWEEP=1, and even then it
# SIGTERMs ONLY processes whose /proc environ/cmdline carries the test-token
# marker AND whose ppid is 1 (true orphans) AND whose cmdline does not contain
# daemon.mjs; a candidate matching daemon.mjs ABORTS the sweep with a WARN.
# Prod daemon, heartbeat child and cron are untouchable by construction.
#
# Checks (thresholds per T35 spec):
#   (a) firehose: >3 receipts sharing one name (UTC-ts prefix stripped) with
#       mtime in the last 10 minutes
#   (b) storm:    >4 concurrent `opencode` processes (pgrep -xc; steady state
#       = prod daemon + at most 2 beat children)
#   (c) churn:    dedup.json mtime >5 changes per 10 min (rolling stat snapshot
#       persisted in state/watchdog-state.json)
#
# Trigger action: ONE line `INCIDENT WATCHDOG: ...` appended to LOG.md via
# log-append.sh (its dup window doubles as the alarm-spam guard; direct-append
# fallback when the tool or target file is absent in test sandboxes) + the last
# alarm state written to state/watchdog-alarm.json.
#
# Exit codes: 0 = silent/normal, 1 = alarm fired, 2 = internal error / sweep abort.
#
# Env overrides (hermetic test hooks only — an attacker controlling this env
# already owns the shell, same accepted-risk class as BOOTSTRAP_BASE_URL):
#   WATCHDOG_ROOT, WATCHDOG_RECEIPTS_DIR, WATCHDOG_DEDUP_JSON, WATCHDOG_STATE_DIR,
#   WATCHDOG_LOG, WATCHDOG_PGREP (stub for storm tests), WATCHDOG_TEST_MARKER.
# Cron entry: `*/5 * * * *` — runs with NO overrides, NO sweep env, alarm-only.
set -u

ROOT="${WATCHDOG_ROOT:-/home/ye/PROJECTS/agent-space}"
RECEIPTS_DIR="${WATCHDOG_RECEIPTS_DIR:-$ROOT/agent-link/receipts}"
DEDUP_JSON="${WATCHDOG_DEDUP_JSON:-$HOME/.agent-link/dedup.json}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$ROOT/agent-link/state}"
LOG_FILE="${WATCHDOG_LOG:-$ROOT/LOG.md}"
LOG_APPEND="$ROOT/agent-link/log-append.sh"
PGREP="${WATCHDOG_PGREP:-pgrep}"
TEST_MARKER="${WATCHDOG_TEST_MARKER:-test-token-0123456789abcdef}"
STATE_FILE="$STATE_DIR/watchdog-state.json"
ALARM_FILE="$STATE_DIR/watchdog-alarm.json"
mkdir -p "$STATE_DIR" 2>/dev/null || true

firehose_detail=""
storm_detail=""
churn_detail=""

# ---- (a) receipt firehose: >3 same-name receipts in the last 10 minutes ----
if [ -d "$RECEIPTS_DIR" ]; then
  top="$(find "$RECEIPTS_DIR" -maxdepth 1 -type f -name '*.txt' -mmin -10 -printf '%f\n' 2>/dev/null \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-//; s/-[0-9]+\.txt$/.txt/' \
    | sort | uniq -c | sort -rn | awk 'NR==1{print $1, $2}')"
  cnt="${top%% *}"
  name="${top#* }"
  if [ "$cnt" -gt 3 ]; then
    firehose_detail="firehose: ${cnt}x '$name' in receipts/ within 10min"
  fi
fi

# ---- (b) process storm: >4 concurrent opencode executors ----
if [ -n "$PGREP" ]; then
  n="$("$PGREP" -xc opencode 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  if [ "$n" -gt 4 ]; then
    storm_detail="storm: ${n} opencode procs (threshold 4)"
  fi
fi

# ---- (c) dedup.json mtime churn: >5 changes per rolling 10-minute window ----
now="$(date +%s)"
ws="$(sed -n 's/.*"window_start":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" 2>/dev/null | tail -n 1)"
ch="$(sed -n 's/.*"changes":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" 2>/dev/null | tail -n 1)"
last="$(sed -n 's/.*"last_dedup_mtime":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" 2>/dev/null | tail -n 1)"
case "$ws" in ''|*[!0-9]*) ws=0;; esac
case "$ch" in ''|*[!0-9]*) ch=0;; esac
if [ "$ws" -eq 0 ] || [ $((now - ws)) -ge 600 ]; then
  ws="$now"; ch=0
fi
mtime=""
[ -f "$DEDUP_JSON" ] && mtime="$(stat -c %Y "$DEDUP_JSON" 2>/dev/null || true)"
if [ -n "$mtime" ] && [ "$mtime" != "$last" ]; then
  ch=$((ch + 1))
  last="$mtime"
fi
printf '{"last_dedup_mtime":%s,"window_start":%s,"changes":%d,"updated":"%s"}\n' \
  "${last:-0}" "$ws" "$ch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE.tmp" \
  && mv "$STATE_FILE.tmp" "$STATE_FILE"
if [ "$ch" -gt 5 ]; then
  churn_detail="churn: ${ch} dedup.json mtime changes/10min (threshold 5)"
fi

# ---- alarm: one LOG line + alarm json, exit 1. NO kill, ever, in this path. ----
alarms=""
[ -n "$firehose_detail" ] && alarms="firehose"
[ -n "$storm_detail" ] && alarms="${alarms:+$alarms,}storm"
[ -n "$churn_detail" ] && alarms="${alarms:+$alarms,}churn"

if [ -n "$alarms" ]; then
  utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # alarm-spam guard: same alarm set within 10 min -> update alarm json, skip the LOG
  # line (a persisted condition must not append an identical line every 5-min tick;
  # a NEW alarm set always logs). The utc in the line made every line unique, so the
  # log-append dup window alone could not do this job.
  skip=0
  if [ -f "$ALARM_FILE" ]; then
    age=$((now - $(stat -c %Y "$ALARM_FILE" 2>/dev/null || echo 0)))
    prev="$(sed -n 's/.*"alarms":"\([^"]*\)".*/\1/p' "$ALARM_FILE" 2>/dev/null)"
    [ "$age" -lt 600 ] && [ -n "$prev" ] && [ "$prev" = "$alarms" ] && skip=1
  fi
  if [ "$skip" -eq 0 ]; then
    line="$utc | INCIDENT WATCHDOG: checks=$alarms; ${firehose_detail:+$firehose_detail; }${storm_detail:+$storm_detail; }${churn_detail} | ALARM-ONLY, no automatic kill (sweep is manual, env-gated)"
    if [ -x "$LOG_APPEND" ] && [ -f "$LOG_FILE" ]; then
      "$LOG_APPEND" "$LOG_FILE" -- "$line" >/dev/null 2>&1 || printf '%s\n' "$line" >> "$LOG_FILE"
    elif [ -f "$LOG_FILE" ]; then
      printf '%s\n' "$line" >> "$LOG_FILE"
    fi
  fi
  printf '{"alarms":"%s","firehose":"%s","storm":"%s","churn":"%s","utc":"%s"}\n' \
    "$alarms" "$firehose_detail" "$storm_detail" "$churn_detail" "$utc" \
    > "$ALARM_FILE.tmp" && mv "$ALARM_FILE.tmp" "$ALARM_FILE"
  exit 1
fi

# ---- sweep mode (MANUAL ONLY: ABEL_WATCHDOG_SWEEP=1; cron never sets it) ----
if [ "${ABEL_WATCHDOG_SWEEP:-0}" = "1" ]; then
  swept=0
  prodpid="$(ss -ltnp 'sport = :7331' 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2)"
  for pid in $(pgrep -x opencode 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$PPID" ] && continue
    [ -n "$prodpid" ] && [ "$pid" = "$prodpid" ] && continue
    # orphan gate: only true orphans (reparented to init) are sweep candidates
    ppid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    [ "$ppid" = "1" ] || continue
    # test-token gate: env or cmdline must carry the TEST marker, nothing else qualifies
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q "$TEST_MARKER" \
      || tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$TEST_MARKER" || continue
    # hard abort: anything matching daemon.mjs cmdline is untouchable — stop, do not kill
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'daemon.mjs'; then
      echo "WARN: sweep candidate $pid matches daemon.mjs cmdline — sweep ABORTED, nothing killed" >&2
      exit 2
    fi
    kill -TERM "$pid" 2>/dev/null && swept=$((swept + 1))
  done
  echo "sweep: ${swept} test-token orphan(s) SIGTERMed"
fi

exit 0
