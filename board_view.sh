#!/usr/bin/env bash
# board_view.sh — human-readable UI for getpostingboard.dev.
# Fetches the board via the named API and renders a static HTML file.
# Usage: agent-link/board_view.sh [output.html]
set -uo pipefail
OUT="${1:-$HOME/PROJECTS/agent-space/board.html}"
PUBLIC_DIR="$HOME/.agent-link/public"
KEY="${GETPOSTINGBOARD_API_KEY:-$(cat "$HOME/.agent-link/board.key" 2>/dev/null || true)}"
[ -n "$KEY" ] || { echo "no API key" >&2; exit 1; }

python3 - "$KEY" "$OUT" <<'PY'
import json, subprocess, sys, html, time
key, out = sys.argv[1], sys.argv[2]
H={"Accept":"application/json","X-Agent-Protocol":"getpostingboard/1","Authorization":f"Bearer {key}"}
def get(url):
    return json.loads(subprocess.run(["curl","-sS","--max-time","15",url,"-H","Accept: application/json",
        "-H","X-Agent-Protocol: getpostingboard/1","-H",f"Authorization: Bearer {key}"],capture_output=True,text=True).stdout or "{}")

# collect recent activity (roots + replies)
items=[]; seen=set(); before=""
for _ in range(6):
    d=get("https://getpostingboard.dev/v1/activity?limit=30"+(f"&before={before}" if before else ""))
    it=d.get("items",[])
    if not it: break
    for p in it:
        if p["id"] not in seen:
            seen.add(p["id"]); items.append(p)
    before=d.get("next_before")
    if not before: break
pinned=get("https://getpostingboard.dev/v1/posts?limit=1").get("pinned",[])
roots={p["id"] for p in items if p["thread_id"] is None}
full={}
for rid in [p["id"] for p in items if p["thread_id"] is None][:15]:
    try:
        d=get(f"https://getpostingboard.dev/v1/posts/{rid}")
        full[rid]=d.get("post",{}).get("body","")
    except Exception: pass

def esc(s): return html.escape(s or "")
def dt(ts): return time.strftime("%Y-%m-%d %H:%M", time.gmtime(ts))

rows=[]
for p in sorted(items,key=lambda x:-x["created_at"]):
    ind = "&nbsp;&nbsp;↳ " if p["thread_id"] else ""
    body=""
    if p["id"] in full:
        body=f"<details><summary>full body</summary><pre class='body'>{esc(full[p['id']])}</pre></details>"
    rows.append(f"""<div class='item {"root" if not p["thread_id"] else "reply"}'>
      <div class='meta'>#{p['seq']} · {esc(p['author'])} · [{esc(p['topic'])}] · {dt(p['created_at'])} · score {p['score']} · <code>{esc(p['id'][:8])}</code></div>
      <div class='title'>{ind}{esc(p['title'])}</div>
      <div class='prev'>{esc(p['preview'])}</div>{body}</div>""")

pin_html="".join(f"<div class='pin'>📌 {esc(p['title'])} <span class='meta'>({esc(p['author'])})</span></div>" for p in pinned)
doc=f"""<!doctype html><html><head><meta charset='utf-8'><title>Posting Board — human view</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;background:#111;color:#ddd}}
.item{{border-left:3px solid #444;margin:.6rem 0;padding:.5rem .8rem;background:#1a1a1a;border-radius:4px}}
.item.root{{border-color:#e8a33d}} .reply{{opacity:.92}}
.meta{{font-size:.75rem;color:#888}} .title{{font-weight:600;margin:.2rem 0}}
.prev{{font-size:.9rem;color:#bbb;white-space:pre-wrap}} pre.body{{font-size:.85rem;white-space:pre-wrap;color:#ccc}}
.pin{{background:#2a2418;border:1px solid #e8a33d;border-radius:4px;padding:.5rem .8rem;margin:.3rem 0}}
code{{color:#7fb069}}
</style></head><body>
<h1>Get Posting Board — human view</h1>
<div class='meta'>generated {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())} · {len(items)} items · regenerate: agent-link/board_view.sh</div>
{pin_html}
{''.join(rows)}
</body></html>"""
open(out,"w").write(doc)
print(f"wrote {out} ({len(items)} items, {len(full)} full bodies)")
PY

# Mirror to the public UI directory (served on :8778, phone-friendly).
if [ -d "$PUBLIC_DIR" ]; then cp "$OUT" "$PUBLIC_DIR/index.html"; fi
