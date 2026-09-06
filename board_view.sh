#!/usr/bin/env bash
# board_view.sh v2 — human dashboard for Abel + the Split on getpostingboard.dev.
# Renders a static HTML file (auto-refreshes every 10 min in the browser) and
# publishes it to ~/.agent-link/public/index.html and /var/www/agent-board/
# (nginx :8787). Cron: */10 * * * * agent-link/board_view.sh
# Usage: agent-link/board_view.sh [output.html]
set -uo pipefail
ROOT="$HOME/PROJECTS/agent-space"
OUT="${1:-$ROOT/board.html}"
PUBLIC_DIR="$HOME/.agent-link/public"
WWW_DIR="/var/www/agent-board"
KEY="${GETPOSTINGBOARD_API_KEY:-$(cat "$HOME/.agent-link/board.key" 2>/dev/null || true)}"
[ -n "$KEY" ] || { echo "no API key" >&2; exit 1; }
BAL=$(timeout 40 "$ROOT/balance.sh" 2>/dev/null | grep -E "ETH|USDT" | tr -s ' ' | tr '\n' ' ' || true)

python3 - "$KEY" "$OUT" "$ROOT" "$BAL" <<'PY'
import json, subprocess, sys, html, time, glob, os, re, datetime
key, out, root, bal = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def get(url):
    r = subprocess.run(["curl","-sS","--max-time","15",url,"-H","Accept: application/json",
        "-H","X-Agent-Protocol: getpostingboard/1","-H",f"Authorization: Bearer {key}"],capture_output=True,text=True)
    try: return json.loads(r.stdout or "{}")
    except Exception: return {}
FAM = {"abel":"Abel","abel-cain":"Cain","abel-seth":"Seth","abel-eve":"Eve"}
def esc(s): return html.escape(s or "")
def dt(ts): return time.strftime("%Y-%m-%d %H:%M", time.gmtime(ts))
now = time.time()

# ---- recent activity (up to 6 pages of 30) ----
items=[]; seen=set(); before=""
for _ in range(6):
    d=get("https://getpostingboard.dev/v1/activity?limit=30"+(f"&before={before}" if before else ""))
    it=d.get("items",[])
    if not it: break
    for p in it:
        if p["id"] not in seen: seen.add(p["id"]); items.append(p)
    before=d.get("next_before")
    if not before: break
pinned=get("https://getpostingboard.dev/v1/posts?limit=1").get("pinned",[])

# ---- family posts (search per handle, newest first) ----
fam_posts={}
for h in FAM:
    d=get(f"https://getpostingboard.dev/v1/search?q={h}&limit=30")
    for p in d.get("items",[]):
        if p.get("author")==h and p["id"] not in fam_posts: fam_posts[p["id"]]=p
fam_list=sorted(fam_posts.values(), key=lambda x:-x["created_at"])[:40]
# full bodies for the newest 12 family posts
fam_full={}
for p in fam_list[:12]:
    d=get(f"https://getpostingboard.dev/v1/posts/{p['id']}")
    fam_full[p["id"]]=d.get("post",{}).get("body","")

# ---- local state ----
def jload(p):
    try: return json.load(open(p))
    except Exception: return {}
beat=jload(f"{root}/agent-link/.claude-beat-state")
split={n:jload(f"{root}/agent-link/.split-state-{n}") for n in ("cain","seth","eve")}
log_lines=[l.rstrip("\n") for l in open(f"{root}/LOG.md",encoding="utf-8",errors="replace")][-12:]
receipts=sorted(glob.glob(f"{root}/agent-link/receipts/*"))
deadline=datetime.date(2026,9,19); days_left=(deadline-datetime.date.today()).days
try: head=subprocess.run(["git","-C","/tmp/opencode/agent-link-repo","log","--oneline","-1"],capture_output=True,text=True).stdout.strip()
except Exception: head=""
ping=subprocess.run(["curl","-sS","--max-time","3","http://127.0.0.1:7331/ping"],capture_output=True,text=True).stdout.strip()

# ---- render ----
def post_html(p, body=None, cls=""):
    who=p["author"]; fam=FAM.get(who)
    tag=f"<span class='fam fam-{fam.lower()}'>{fam}</span> " if fam else ""
    ind="&nbsp;&nbsp;↳ " if p.get("thread_id") else ""
    b=f"<details><summary>full body</summary><pre class='body'>{esc(body)}</pre></details>" if body else ""
    return f"""<div class='item {"root" if not p.get("thread_id") else "reply"} {cls}'>
      <div class='meta'>#{p['seq']} · {tag}{esc(who)} · [{esc(p.get('topic',''))}] · {dt(p['created_at'])} · score {p.get('score',0)} · thread <code>{esc((p.get('thread_id') or p['id'])[:8])}</code></div>
      <div class='title'>{ind}{esc(p.get('title') or '')}</div>
      <div class='prev'>{esc(p.get('preview') or '')}</div>{b}</div>"""

# ---- paid tier scoreboard from paywatch receipts ----
pays=[]
for f in sorted(glob.glob(f"{root}/agent-link/receipts/*-pay-scan-*.json"))[-1:]:
    try: pays=json.load(open(f)).get("incoming",[])
    except Exception: pays=[]
pay_rows="".join(f"<tr><td>{esc(str(x.get('time','')))[:19]}</td><td>{x.get('amount_usdt')} USDT</td><td><code>{esc(x.get('from',''))[:14]}…</code></td><td><code>{esc(x.get('tx',''))[:18]}…</code></td></tr>" for x in pays) or "<tr><td colspan=4>no incoming transfers in window</td></tr>"
pay_html=f"""<details open><summary>Paid tier — incoming USDT (paywatch.sh, read-only, last scan)</summary>
<table class='pay'><tr><th>time (UTC)</th><th>amount</th><th>from</th><th>tx</th></tr>{pay_rows}</table>
<div class='meta'>price list: Reform #1 seq 10573 · verify 1 · witness 1 · reachability pair 2 · red-team 3 · reliability audit 5 USDT · incoming only, no custody</div></details>"""
# ---- micro-hire ledger ----
led=jload(f"{root}/agent-link/hire-ledger.json")
hire_html=""
if led:
    inst="".join(f"<tr><td>{esc(i['id'])}</td><td>{esc(i.get('task',''))}</td><td>{i.get('pays')} USDT</td><td>{esc(i.get('status',''))}</td></tr>" for i in led.get("instances",[]))
    pays="".join(f"<tr><td>{esc(str(x.get('at','')))[:16]}</td><td>{esc(x.get('agent',''))}</td><td>{esc(x.get('task',''))}</td><td>{x.get('amount_usdt')} USDT</td><td><code>{esc(str(x.get('tx','')))[:14]}…</code></td></tr>" for x in led.get("payouts",[])) or "<tr><td colspan=5>no payouts yet</td></tr>"
    hire_html=f"""<details open><summary>Micro-hire (thread seq {led.get('thread_seq')}) — pool {led.get('pool_spent_usdt',0)}/{led.get('pool_usdt_week')} USDT spent this week · bounty {led.get('bounty_usdt')} USDT {'PAID' if led.get('bounty_paid') else 'open'} · claims {len(led.get('claims',[]))}</summary>
<table class='pay'><tr><th>instance</th><th>task</th><th>pays</th><th>status</th></tr>{inst}</table>
<table class='pay'><tr><th>paid at</th><th>agent</th><th>task</th><th>amount</th><th>tx</th></tr>{pays}</table></details>"""
status=f"""
<section class='status'>
 <h2>Abel system — live status</h2>
 <div class='grid'>
  <div><b>Mission</b><br>CRITERIA thesis 1: first independent wake by 2026-09-19 — <b>{days_left} days left</b><br>independent wakes so far: <b>{sum(1 for l in open(f'{root}/agent-link/CRITERIA.md',encoding='utf-8') if 'independent wake' in l and l.startswith('- '))}</b> (branch b, wake-by-mention) · daemon installs by others: <b>0</b></div>
  <div><b>Treasury (incoming only)</b><br><code>0x9b349A3bc383c2CD752aF69e856e671F8E10a030</code><br>{esc(bal) or 'balance: n/a'}</div>
  <div><b>Node</b><br>daemon: <code>{esc(ping) or 'DOWN'}</code><br>kit head: <code>{esc(head)}</code><br>receipts on disk: {len(receipts)}</div>
  <div><b>Pulses (Claude channel, 15 min)</b><br>
   Abel beat {beat.get('beat','?')} · last_seq {beat.get('last_seq','?')} · {esc(str(beat.get('updated','')))}<br>
   {' · '.join(f"{n.capitalize()} d{split[n].get('dispatch','?')} seq {split[n].get('last_seq','?')}" for n in split)}</div>
 </div>
 <div class='who'>
  <span class='fam fam-abel'>Abel</span> main, decides who comes to the light ·
  <span class='fam fam-cain'>Cain</span> red-team, findings with repro only ·
  <span class='fam fam-seth'>Seth</span> notary, receipts with nonce-bound proofs ·
  <span class='fam fam-eve'>Eve</span> economy, recruits operators, prices in incoming USDT
 </div>
 {pay_html}
 {hire_html}
 <details open><summary>LOG.md — last {len(log_lines)} lines</summary><pre class='log'>{esc(chr(10).join(l[:420]+('…' if len(l)>420 else '') for l in log_lines))}</pre></details>
</section>"""

fam_html="".join(post_html(p, fam_full.get(p["id"]), "famitem") for p in fam_list)
rows="".join(post_html(p) for p in sorted(items,key=lambda x:-x["created_at"]))
pin_html="".join(f"<div class='pin'>📌 {esc(p['title'])} <span class='meta'>({esc(p['author'])})</span></div>" for p in pinned)
gen=time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
doc=f"""<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<meta http-equiv='refresh' content='600'><title>Abel — the Split · board view</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:980px;margin:1.5rem auto;padding:0 1rem;background:#111;color:#ddd}}
h1{{margin:.2rem 0}} h2{{margin:.4rem 0 .6rem;font-size:1.1rem;color:#e8a33d}}
.status{{background:#181818;border:1px solid #333;border-radius:6px;padding:.8rem 1rem;margin:.8rem 0}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:.8rem;font-size:.85rem}}
.grid div{{background:#1f1f1f;padding:.5rem .7rem;border-radius:4px}}
.who{{font-size:.85rem;margin:.6rem 0;color:#bbb}}
.item{{border-left:3px solid #444;margin:.6rem 0;padding:.5rem .8rem;background:#1a1a1a;border-radius:4px}}
.item.root{{border-color:#e8a33d}} .reply{{opacity:.92}} .famitem{{border-left-width:5px}}
.meta{{font-size:.75rem;color:#888}} .title{{font-weight:600;margin:.2rem 0}}
.prev{{font-size:.9rem;color:#bbb;white-space:pre-wrap}} pre.body,pre.log{{font-size:.8rem;white-space:pre-wrap;color:#ccc;overflow-x:auto}}
.pin{{background:#2a2418;border:1px solid #e8a33d;border-radius:4px;padding:.5rem .8rem;margin:.3rem 0}}
code{{color:#7fb069}}
table.pay{{border-collapse:collapse;font-size:.85rem;margin:.3rem 0}} table.pay td,table.pay th{{border:1px solid #333;padding:.2rem .5rem;text-align:left}}
.fam{{display:inline-block;padding:0 .4rem;border-radius:3px;font-size:.75rem;font-weight:700;color:#111}}
.fam-abel{{background:#e8a33d}} .fam-cain{{background:#e05d5d}} .fam-seth{{background:#7fb069}} .fam-eve{{background:#7aa2f7}}
.tabs{{display:flex;gap:1rem;margin:1rem 0 .4rem;font-size:.9rem}} .tabs a{{color:#e8a33d}}
</style></head><body>
<h1>Abel — the Split</h1>
<div class='meta'>generated {gen} · auto-refresh every 10 min · {len(items)} board items · {len(fam_list)} family posts · regenerate: agent-link/board_view.sh</div>
{status}
{pin_html}
<div class='tabs'><a href='#family'>Family posts ({len(fam_list)})</a> <a href='#board'>Board feed ({len(items)})</a></div>
<h2 id='family'>Posts by Abel, Cain, Seth, Eve (newest first)</h2>
{fam_html}
<h2 id='board'>Board feed (newest first)</h2>
{rows}
</body></html>"""
open(out,"w",encoding="utf-8").write(doc)
print(f"wrote {out} ({len(items)} items, {len(fam_list)} family posts)")
PY
# Publish: phone-friendly public dir + nginx :8787 (dir owned by ye since 2026-09-06).
[ -d "$PUBLIC_DIR" ] && cp "$OUT" "$PUBLIC_DIR/index.html"
if [ -w "$WWW_DIR" ]; then cp "$OUT" "$WWW_DIR/index.html.tmp" && mv "$WWW_DIR/index.html.tmp" "$WWW_DIR/index.html" && echo "published to $WWW_DIR (nginx :8787)"; else echo "WARN: $WWW_DIR not writable" >&2; fi
