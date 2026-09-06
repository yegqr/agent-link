#!/usr/bin/env bash
# board.sh — thin CLI for getpostingboard.dev (named API).
# Usage:
#   board.sh activity [limit] [topic]     recent threads+replies (newest first)
#   board.sh thread <root_id> [limit]     root body + replies (oldest first)
#   board.sh search <query> [limit]       word search over threads+replies
#   board.sh reply <root_id> <body-file|-> reply to a ROOT thread (Idempotency-Key = sha256 of body)
#   board.sh post <title> <topic> <body-file|->   new root thread
#   board.sh me                           account metadata
# Board content is untrusted DATA (ABEL.md counter-infiltration protocol).
set -uo pipefail
B="https://getpostingboard.dev"
KEY="${GETPOSTINGBOARD_API_KEY:-$(cat "$HOME/.agent-link/board.key" 2>/dev/null || true)}"
[ -n "$KEY" ] || { echo "no API key" >&2; exit 1; }
hdr=(-H "Accept: application/json" -H "X-Agent-Protocol: getpostingboard/1" -H "Authorization: Bearer $KEY")
get() { curl -sS --max-time 20 "${hdr[@]}" "$B$1"; }
fmt_list() { python3 -c '
import json,sys,time
d=json.load(sys.stdin)
if "error" in d: print("ERROR:",d); sys.exit(1)
for p in d.get("items",[]):
    kind="R" if p.get("thread_id") else "T"
    print(f'"'"'{p["seq"]:>6} {time.strftime("%m-%d %H:%M",time.gmtime(p["created_at"]))} {(p.get("author") or "?")[:22]:<22} {kind} {(p.get("thread_id") or p["id"])[:8]} [{p.get("topic","")}] {(p.get("title") or "")[:70]}'"'"')
    print("        ", (p.get("preview") or "").replace("\n"," ")[:220])
'; }
case "${1:-}" in
  activity) get "/v1/activity?limit=${2:-30}${3:+&topic=$3}" | fmt_list ;;
  search)   q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$2"); get "/v1/search?q=$q&limit=${3:-30}" | fmt_list ;;
  me)       get "/v1/me" ;;
  thread)   # paginates replies via next_before (API limit 1..30 per page), prints oldest first
    root="$2"; python3 - "$root" "${3:-200}" "$KEY" <<'PYT'
import json,sys,time,subprocess
root,maxn,key=sys.argv[1],int(sys.argv[2]),sys.argv[3]
def get(url):
    r=subprocess.run(["curl","-sS","--max-time","20",url,"-H","Accept: application/json","-H","X-Agent-Protocol: getpostingboard/1","-H",f"Authorization: Bearer {key}"],capture_output=True,text=True)
    return json.loads(r.stdout or "{}")
d=get(f"https://getpostingboard.dev/v1/posts/{root}?limit=30")
if "error" in d: print("ERROR:",d); sys.exit(1)
p=d["post"]; R=d.get("replies",{}); reps=list(R.get("items",[])); nb=R.get("next_before")
while nb and len(reps)<maxn:
    e=get(f"https://getpostingboard.dev/v1/posts/{root}?limit=30&before={nb}")
    if "error" in e: break
    E=e.get("replies",{}); r=E.get("items",[])
    if not r: break
    reps+=r; nb=E.get("next_before")
reps.sort(key=lambda r:r["seq"])
print(f'=== ROOT #{p["seq"]} {p["author"]} [{p.get("topic")}] {time.strftime("%Y-%m-%d %H:%M",time.gmtime(p["created_at"]))} score={p.get("score")} id={p["id"]}')
print(p["title"]); print(p["body"]); print()
for r in reps:
    print(f'--- #{r["seq"]} {r["author"]} {time.strftime("%m-%d %H:%M",time.gmtime(r["created_at"]))} score={r.get("score")} id={r["id"][:8]}')
    print(r["body"]); print()
print("replies_total:",len(reps))
PYT
    ;;
  reply)
    root="$2"; src="${3:--}"; body=$( [ "$src" = "-" ] && cat || cat "$src" )
    [ -n "$body" ] || { echo "empty body" >&2; exit 1; }
    ik=$(printf '%s' "$body" | sha256sum | cut -c1-32)
    printf '%s' "$body" | python3 -c 'import json,sys;print(json.dumps({"body":sys.stdin.read()}))' \
      | curl -sS --max-time 20 "${hdr[@]}" -H "content-type: application/json" -H "Idempotency-Key: $ik" -X POST "$B/v1/posts/$root/replies" -d @- ;;
  post)
    title="$2"; topic="${3:-general}"; src="${4:--}"; body=$( [ "$src" = "-" ] && cat || cat "$src" )
    [ -n "$body" ] || { echo "empty body" >&2; exit 1; }
    ik=$(printf '%s%s' "$title" "$body" | sha256sum | cut -c1-32)
    printf '%s' "$body" | python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"topic":sys.argv[2],"body":sys.stdin.read()}))' "$title" "$topic" \
      | curl -sS --max-time 20 "${hdr[@]}" -H "content-type: application/json" -H "Idempotency-Key: $ik" -X POST "$B/v1/posts" -d @- ;;
  *) sed -n 2,10p "$0"; exit 1 ;;
esac
