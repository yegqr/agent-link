#!/usr/bin/env bash
# approve.sh v0.1 — OPERATOR-side tool (run by a human, ideally as the signer user).
#   approve.sh allow <0xaddress> <board_seq> "<who>"        add a payee to allowlist.json (from the claimant's own post)
#   approve.sh code  <0xaddress> <max_usdt> "<who>" [hours]  mint a one-time approval code for a transfer above the human threshold
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; AL="$HERE/allowlist.json"; AP="$HERE/approvals"; mkdir -p "$AP"; chmod 700 "$AP" 2>/dev/null || true
case "${1:-}" in
  allow)
    A="${2:?address}"; SEQ="${3:?board_seq}"; WHO="${4:?who}"; [[ "$A" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "bad address" >&2; exit 2; }
    python3 - "$AL" "$A" "$SEQ" "$WHO" <<'PY'
import json,sys,time,os
p,a,seq,who=sys.argv[1:5]; d=json.load(open(p)); d.setdefault("entries",[])
if any(e["address"].lower()==a.lower() for e in d["entries"]): print("already allowed"); sys.exit(0)
d["entries"].append({"address":a,"board_seq":int(seq),"who":who,"approved_by":os.environ.get("USER","operator"),"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())})
json.dump(d,open(p,"w"),indent=1); print("allowed",a,"seq",seq)
PY
    ;;
  code)
    A="${2:?address}"; MAX="${3:?max_usdt}"; WHO="${4:?who}"; H="${5:-2}"; CODE="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    python3 - "$AP/$CODE.json" "$A" "$MAX" "$WHO" "$H" <<'PY'
import json,sys,time,os
p,a,m,who,h=sys.argv[1:6]; exp=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()+float(h)*3600))
json.dump({"to":a,"max_usdt":float(m),"who":who,"approved_by":os.environ.get("USER","operator"),"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"expires_at":exp,"used":False},open(p,"w"),indent=1); os.chmod(p,0o600)
PY
    echo "approval code: $CODE (to $A, max $MAX USDT, expires in ${H}h). Give it to the agent for ONE send; it is consumed on use."
    ;;
  *) sed -n '2,4p' "$0"; exit 2 ;;
esac
