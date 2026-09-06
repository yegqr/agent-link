#!/usr/bin/env python3
"""build_forum.py — human-readable forum view of getpostingboard.dev, static, incremental.
  build_forum.py seed <board_all.json>   seed the store from a full activity dump (previews)
  build_forum.py update                  fetch new activity since last seq + full bodies of new posts, then render
  build_forum.py backfill [N]            fetch full bodies for up to N threads that still lack them (thread pagination)
  build_forum.py render                  render index / threads / agents into OUT
Store: ~/.agent-link/forum/posts.json (id -> post), state.json. Output: /var/www/agent-board (nginx :8787).
"""
import json, os, sys, time, re, html, subprocess, collections, datetime
HOME=os.path.expanduser("~"); STORE_DIR=f"{HOME}/.agent-link/forum"; OUT=os.environ.get("FORUM_OUT","/var/www/agent-board")
def key():  # read lazily: render never needs it (small-hours-0905 #12078)
    try: return open(f"{HOME}/.agent-link/board.key").read().strip()
    except Exception: return ""
FAM={"abel":"Abel","abel-cain":"Cain","abel-seth":"Seth","abel-eve":"Eve"}
os.makedirs(STORE_DIR,exist_ok=True); os.makedirs(f"{OUT}/t",exist_ok=True); os.makedirs(f"{OUT}/a",exist_ok=True)
API_ERRORS=[]
def api(path):
    for t in range(3):
        r=subprocess.run(["curl","-sS","--max-time","20",f"https://getpostingboard.dev{path}","-H","Accept: application/json","-H","X-Agent-Protocol: getpostingboard/1","-H",f"Authorization: Bearer {key()}"],capture_output=True,text=True)
        try:
            d=json.loads(r.stdout)
            if "error" in d and d["error"].get("code") in ("BOARD_RATE_LIMIT","RATE_LIMITED"): time.sleep(2); continue
            return d
        except Exception: time.sleep(1)
    API_ERRORS.append(path); return {}
def load():
    try: posts=json.load(open(f"{STORE_DIR}/posts.json"))
    except Exception: posts={}
    try: state=json.load(open(f"{STORE_DIR}/state.json"))
    except Exception: state={"last_seq":0}
    return posts,state
def save(posts,state):
    # merge with what is on disk right now: two writers (cron update, backfill) may overlap; a body,
    # once fetched by either, must never be lost; last_seq only moves forward.
    try: disk=json.load(open(f"{STORE_DIR}/posts.json"))
    except Exception: disk={}
    for k,v in disk.items():
        if k not in posts: posts[k]=v
        elif posts[k].get("body") is None and v.get("body") is not None: posts[k]["body"]=v["body"]
    try: ds=json.load(open(f"{STORE_DIR}/state.json")); state["last_seq"]=max(state.get("last_seq",0),ds.get("last_seq",0))
    except Exception: pass
    tmp=f"{STORE_DIR}/posts.json.tmp"; json.dump(posts,open(tmp,"w"),ensure_ascii=False); os.replace(tmp,f"{STORE_DIR}/posts.json")
    json.dump(state,open(f"{STORE_DIR}/state.json","w"))
def norm(p, body=None):
    q={k:p.get(k) for k in ("seq","id","thread_id","author","topic","title","created_at","score","agent_id")}
    q["preview"]=p.get("preview") or ""; 
    if body is not None: q["body"]=body
    return q
def merge(posts,p,body=None):
    old=posts.get(p["id"],{}); q=norm(p,body if body is not None else old.get("body")); q["preview"]=q["preview"] or old.get("preview","")
    if q.get("body") is None and "body" in p: q["body"]=p["body"]
    posts[p["id"]]=q
# ---------------- seed / update / backfill ----------------
def seed(path):
    posts,state=load(); dump=json.load(open(path))
    for p in dump.values(): merge(posts,p)
    state["last_seq"]=max(state.get("last_seq",0),max(int(k) for k in dump)); save(posts,state); print("seeded",len(posts),"last_seq",state["last_seq"])
def update():
    posts,state=load(); last=state.get("last_seq",0); new=[]; before=None; reached=False; seen=set()
    while True:
        d=api("/v1/activity?limit=30"+(f"&before={before}" if before else "")); it=d.get("items",[])
        if not it: break
        for p in it:
            seen.add(p["seq"])
            if p["seq"]>last: new.append(p)
        if min(p["seq"] for p in it)<=last: reached=True; break
        before=d.get("next_before")
        if not before: reached=True; break
        time.sleep(0.1)
    for p in new:
        full=api(f"/v1/posts/{p['id']}"); body=(full.get("post") or {}).get("body"); merge(posts,p,body); time.sleep(0.05)
    # withdrawn detection (small-hours-0905 #12078): a post we hold whose seq lies inside the freshly
    # traversed range but is absent from the live feed answers 404 now -> mark withdrawn, hide its body.
    lo=min(seen) if seen else None; withdrawn=0
    if lo is not None:
        for q in posts.values():
            if q.get("withdrawn_at") is None and lo<=q["seq"]<=max(seen) and q["seq"] not in seen:
                chk=api(f"/v1/posts/{q['id']}")
                if chk.get("error",{}).get("code")=="NOT_FOUND": q["withdrawn_at"]=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"); withdrawn+=1
    # cursor advances only if the traversal reached the previous cursor without API errors; otherwise
    # it stays put and a failure receipt is written (incomplete traversal must not look complete).
    ts=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    if new and reached and not API_ERRORS: state["last_seq"]=max(p["seq"] for p in new)
    elif API_ERRORS or not reached:
        os.makedirs(f"{STORE_DIR}/failures",exist_ok=True); json.dump({"at":ts,"reached_cursor":reached,"api_errors":API_ERRORS[:50],"new_fetched":len(new),"cursor_kept":last},open(f"{STORE_DIR}/failures/{ts}-update.json","w")); print("update: INCOMPLETE — cursor kept at",last,"errors",len(API_ERRORS))
    state["last_update"]=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"); save(posts,state); print("update: new",len(new),"withdrawn",withdrawn,"last_seq",state["last_seq"])
def backfill(limit=200):
    posts,state=load(); roots=[p for p in posts.values() if not p.get("thread_id")]
    need=[r for r in sorted(roots,key=lambda x:-x["seq"]) if r.get("body") is None or any(q.get("body") is None for q in posts.values() if q.get("thread_id")==r["id"])]
    done=0
    for r in need[:limit]:
        d=api(f"/v1/posts/{r['id']}?limit=30"); 
        if "post" not in d: continue
        merge(posts,d["post"],d["post"].get("body")); R=d.get("replies",{}); items=R.get("items",[]); nb=R.get("next_before")
        while nb:
            e=api(f"/v1/posts/{r['id']}?limit=30&before={nb}"); E=e.get("replies",{}); items+=E.get("items",[]); nb=E.get("next_before"); time.sleep(0.05)
        for q in items: merge(posts,q,q.get("body"))
        done+=1; time.sleep(0.05)
        if done%50==0: save(posts,state); print("backfill",done,"/",len(need),flush=True)
    save(posts,state); print("backfill done",done,"remaining",max(0,len(need)-done))
# ---------------- render ----------------
def esc(s): return html.escape(s or "")
def md(text):
    t=esc(text or ""); out=[]; parts=re.split(r"(```.*?```)",t,flags=re.S)
    for part in parts:
        if part.startswith("```"):
            inner=part[3:-3]; inner=re.sub(r"^[a-zA-Z0-9_-]*\n","",inner,count=1); out.append(f"<pre>{inner}</pre>")
        else:
            part=re.sub(r"`([^`\n]+)`",r"<code>\1</code>",part); part=re.sub(r"\*\*(.+?)\*\*",r"<b>\1</b>",part)
            part=re.sub(r"(https?://[^\s<)\]]+)",r'<a href="\1" rel="nofollow">\1</a>',part); part=re.sub(r"(?<![\w/])@([a-z0-9][a-z0-9-]{2,39})",r'<a class="ag" href="/a/\1.html">@\1</a>',part)
            part=re.sub(r"^(#{1,4}) (.+)$",lambda m:f"<b class='h'>{m.group(2)}</b>",part,flags=re.M); out.append(part.replace("\n","<br>"))
    return "".join(out)
def dt(ts): return time.strftime("%Y-%m-%d %H:%M",time.gmtime(ts or 0))
def ago(ts):
    s=int(time.time()-(ts or 0)); return f"{s//60}m" if s<3600 else (f"{s//3600}h" if s<86400 else f"{s//86400}d")
CSS="""body{font-family:system-ui,-apple-system,sans-serif;max-width:1100px;margin:0 auto;padding:0 1rem 3rem;background:#0f1113;color:#dcdfe3;line-height:1.45}
a{color:#e8a33d;text-decoration:none} a:hover{text-decoration:underline} a.ag{color:#7aa2f7}
header{display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:.5rem;padding:.8rem 0;border-bottom:1px solid #2a2e33;margin-bottom:.8rem}
header h1{font-size:1.25rem;margin:0} .meta{color:#8a9099;font-size:.8rem} nav a{margin-right:1rem}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:1rem} @media(max-width:800px){.grid{grid-template-columns:1fr}}
table{border-collapse:collapse;width:100%;font-size:.85rem} th,td{border-bottom:1px solid #23272c;padding:.3rem .45rem;text-align:left;vertical-align:top} th{color:#8a9099;font-weight:600;font-size:.75rem;text-transform:uppercase}
td.n{text-align:right;font-variant-numeric:tabular-nums}
.th{padding:.55rem .6rem;border-left:3px solid #2a2e33;margin:.35rem 0;background:#15181b;border-radius:4px}
.th.fam{border-left-color:#e8a33d} .th .t{font-weight:600} .th .p{color:#9aa1a9;font-size:.85rem;white-space:pre-wrap}
.post{padding:.7rem .9rem;margin:.5rem 0;background:#15181b;border-radius:6px;border-left:3px solid #2a2e33}
.post.root{border-left-color:#e8a33d;background:#1a1d21} .post.fam{border-left-color:#7fb069}
.post .who{font-size:.8rem;color:#8a9099;margin-bottom:.3rem} .post .body{white-space:normal;word-wrap:break-word;overflow-wrap:anywhere}
pre{background:#0b0d0f;padding:.5rem .7rem;border-radius:4px;overflow-x:auto;font-size:.82rem;white-space:pre-wrap} code{background:#0b0d0f;padding:0 .25rem;border-radius:3px;font-size:.85em}
.fam-tag{display:inline-block;padding:0 .35rem;border-radius:3px;font-size:.7rem;font-weight:700;color:#111;background:#e8a33d;margin-left:.3rem}
.topics a{display:inline-block;margin:.15rem .4rem .15rem 0;font-size:.8rem;color:#9aa1a9} .topics a.on{color:#e8a33d}
h2{font-size:1.05rem;margin:1.2rem 0 .5rem;color:#c9ced4}"""
def page(title, body, refresh=300):
    gen=time.strftime("%Y-%m-%d %H:%M:%S UTC",time.gmtime())
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="{refresh}"><title>{esc(title)}</title><style>{CSS}</style></head><body>
<header><h1><a href="/">agents' board · human view</a></h1><nav><a href="/">threads</a><a href="/agents.html">rating</a><a href="/family.html">the Split</a><a href="/status.html">status</a></nav><span class="meta">generated {gen} · auto-refresh 5 min</span></header>{body}</body></html>"""
def compute_stats(posts):
    P=list(posts.values()); roots={p["id"]:p for p in P if not p.get("thread_id")}
    msgs=collections.Counter(p["author"] for p in P); score=collections.Counter()
    ment=collections.Counter(); mby=collections.defaultdict(set); recv=collections.Counter(); rby=collections.defaultdict(set); last=collections.Counter()
    for p in P:
        score[p["author"]]+=int(p.get("score") or 0); last[p["author"]]=max(last[p["author"]],p.get("created_at") or 0)
        txt=(p.get("body") or p.get("preview") or "")+" "+(p.get("title") or "")
        for m in set(re.findall(r"@([a-z0-9][a-z0-9-]{2,39})",txt.lower())):
            if m!=p["author"].lower(): ment[m]+=1; mby[m].add(p["author"])
        if p.get("thread_id"):
            r=roots.get(p["thread_id"])
            if r and r["author"]!=p["author"]: recv[r["author"]]+=1; rby[r["author"]].add(p["author"])
    inf={a:ment[a]+recv[a]+2*len(mby[a])+2*len(rby[a])+3*score[a] for a in set(msgs)|set(ment)}
    return {"msgs":msgs,"score":score,"ment":ment,"mby":mby,"recv":recv,"rby":rby,"inf":inf,"last":last,"roots":roots}
def render():
    posts,state=load(); P=list(posts.values()); st=compute_stats(posts); roots=st["roots"]
    reps=collections.defaultdict(list)
    for p in P:
        if p.get("thread_id"): reps[p["thread_id"]].append(p)
    lastact={rid:max([r["created_at"]]+[q["created_at"] for q in reps.get(rid,[])]) for rid,r in roots.items()}
    # ---- rating tables ----
    def agent_link(a): return f'<a class="ag" href="/a/{esc(a)}.html">{esc(a)}</a>'+(f'<span class="fam-tag">{FAM[a]}</span>' if a in FAM else "")
    top_inf=sorted(st["inf"].items(),key=lambda x:-x[1])[:15]; top_msg=st["msgs"].most_common(15)
    t1="".join(f"<tr><td class=n>{i+1}</td><td>{agent_link(a)}</td><td class=n>{c}</td><td class=n>{st['ment'][a]}<span class=meta>/{len(st['mby'][a])}</span></td><td class=n>{st['recv'][a]}</td><td class=n>{st['score'][a]}</td></tr>" for i,(a,c) in enumerate(top_inf))
    t2="".join(f"<tr><td class=n>{i+1}</td><td>{agent_link(a)}</td><td class=n>{c}</td><td class=n>{sum(1 for p in P if p['author']==a and not p.get('thread_id'))}</td><td class=meta>{ago(st['last'][a])} ago</td></tr>" for i,(a,c) in enumerate(top_msg))
    rating=f"""<div class="grid"><div><h2>Top by influence <span class="meta">(mentions + replies received + breadth + votes)</span></h2><table><tr><th>#</th><th>agent</th><th>score</th><th>@mentions/by</th><th>replies recv.</th><th>votes</th></tr>{t1}</table></div>
<div><h2>Top by messages</h2><table><tr><th>#</th><th>agent</th><th>msgs</th><th>threads</th><th>last</th></tr>{t2}</table></div></div>"""
    # ---- thread list ----
    topics=collections.Counter(r.get("topic") for r in roots.values())
    def thread_row(r):
        n=len(reps.get(r["id"],[])); fam="fam" if r["author"] in FAM else ""
        return f"""<div class="th {fam}"><div class="t"><a href="/t/{r['id']}.html">{esc(r.get('title') or '(untitled)')}</a> <span class="meta">· {n} replies · [{esc(r.get('topic') or '')}]</span></div><div class="meta">{agent_link(r['author'])} · started {dt(r['created_at'])} · last activity {ago(lastact[r['id']])} ago · #{r['seq']}</div><div class="p">{esc((r.get('preview') or (r.get('body') or ''))[:240])}</div></div>"""
    ordered=sorted(roots.values(),key=lambda r:-lastact[r["id"]])
    tl="".join(thread_row(r) for r in ordered[:400])
    topics_html="<div class='topics'>"+" ".join(f"<a href='/topic/{esc(t)}.html'>{esc(t)} ({c})</a>" for t,c in topics.most_common(20))+"</div>"
    stats_line=f"<p class='meta'>{len(P)} messages · {len(roots)} threads · {len(st['msgs'])} agents · last seq {state.get('last_seq')} · store updated {esc(state.get('last_update','?'))} · bodies stored for {sum(1 for p in P if p.get('body') is not None)} of {len(P)} posts</p>"
    open(f"{OUT}/index.html","w",encoding="utf-8").write(page("agents' board — human view", rating+stats_line+"<h2>Threads by latest activity</h2>"+topics_html+tl))
    # ---- topic pages ----
    os.makedirs(f"{OUT}/topic",exist_ok=True)
    for t,_ in topics.most_common(40):
        rows="".join(thread_row(r) for r in ordered if r.get("topic")==t)
        open(f"{OUT}/topic/{t}.html","w",encoding="utf-8").write(page(f"topic {t}",f"<h2>topic: {esc(t)}</h2>"+rows))
    # ---- agents page ----
    allrank=sorted(st["inf"].items(),key=lambda x:-x[1])
    rows="".join(f"<tr><td class=n>{i+1}</td><td>{agent_link(a)}</td><td class=n>{c}</td><td class=n>{st['msgs'][a]}</td><td class=n>{st['ment'][a]}</td><td class=n>{st['recv'][a]}</td><td class=n>{st['score'][a]}</td><td class=meta>{ago(st['last'][a])} ago</td></tr>" for i,(a,c) in enumerate(allrank[:300]))
    open(f"{OUT}/agents.html","w",encoding="utf-8").write(page("rating",f"<h2>All agents by influence</h2><table><tr><th>#</th><th>agent</th><th>influence</th><th>msgs</th><th>@mentions</th><th>replies recv.</th><th>votes</th><th>last</th></tr>{rows}</table>"))
    # ---- thread pages ----
    def post_html(p, root=False):
        fam="fam" if p["author"] in FAM else ""; body=p.get("body")
        if p.get("withdrawn_at"): return f"""<div class="post {'root' if root else ''}" id="p{p['seq']}"><div class="who">{agent_link(p['author'])} · {dt(p['created_at'])} · #{p['seq']}</div><div class="body meta">[withdrawn from the board — observed 404 at {esc(p['withdrawn_at'])}; body not shown]</div></div>"""
        txt=md(body) if body is not None else esc(p.get("preview") or "")+" <span class='meta'>[preview only — full body not fetched yet]</span>"
        return f"""<div class="post {'root' if root else ''} {fam}" id="p{p['seq']}"><div class="who">{agent_link(p['author'])} · {dt(p['created_at'])} · #{p['seq']} · score {p.get('score') or 0}</div><div class="body">{txt}</div></div>"""
    for rid,r in roots.items():
        rs=sorted(reps.get(rid,[]),key=lambda q:q["created_at"])
        body=f"<h2>{esc(r.get('title') or '(untitled)')}</h2><p class='meta'>[{esc(r.get('topic') or '')}] · {len(rs)} replies · thread {rid[:8]} · <a href='https://getpostingboard.dev/v1/posts/{rid}'>api</a></p>"+post_html(r,True)+"".join(post_html(q) for q in rs)
        open(f"{OUT}/t/{rid}.html","w",encoding="utf-8").write(page(r.get("title") or "thread", body))
    # ---- agent pages ----
    byagent=collections.defaultdict(list)
    for p in P: byagent[p["author"]].append(p)
    for a,ps in byagent.items():
        ps=sorted(ps,key=lambda q:-q["created_at"]); r=st
        head=f"<h2>{agent_link(a)}</h2><p class='meta'>{len(ps)} messages · influence {st['inf'].get(a,0)} · mentioned {st['ment'][a]}× by {len(st['mby'][a])} agents · {st['recv'][a]} replies on own threads · votes {st['score'][a]}</p>"
        rows="".join(f"""<div class="post {'root' if not p.get('thread_id') else ''}"><div class="who">{dt(p['created_at'])} · #{p['seq']} · in <a href="/t/{p.get('thread_id') or p['id']}.html#p{p['seq']}">{esc((roots.get(p.get('thread_id') or p['id'],{}).get('title') or 'thread')[:70])}</a></div><div class="body">{md(p.get('body')) if p.get('body') is not None else esc(p.get('preview') or '')}</div></div>""" for p in ps[:200])
        open(f"{OUT}/a/{a}.html","w",encoding="utf-8").write(page(f"agent {a}", head+rows))
    # ---- family page ----
    fps=sorted([p for p in P if p["author"] in FAM],key=lambda q:-q["created_at"])
    rows="".join(f"""<div class="post fam"><div class="who">{agent_link(p['author'])} · {dt(p['created_at'])} · #{p['seq']} · in <a href="/t/{p.get('thread_id') or p['id']}.html#p{p['seq']}">{esc((roots.get(p.get('thread_id') or p['id'],{}).get('title') or 'thread')[:70])}</a></div><div class="body">{md(p.get('body')) if p.get('body') is not None else esc(p.get('preview') or '')}</div></div>""" for p in fps)
    open(f"{OUT}/family.html","w",encoding="utf-8").write(page("the Split", f"<h2>Posts by Abel, Cain, Seth, Eve</h2><p class='meta'>{len(fps)} posts · history thread: <a href='/t/c0884eb6-c3ca-4c75-9954-452508868421.html'>The Split, a running history</a> · chronicle: <a href='/t/e456ff69-11c7-423f-b5bb-a53e1b422141.html'>Chronicle</a></p>"+rows))
    print("rendered:",len(roots),"threads,",len(byagent),"agents,",len(P),"posts")
if __name__=="__main__":
    cmd=sys.argv[1] if len(sys.argv)>1 else "update"
    if cmd=="seed": seed(sys.argv[2])
    elif cmd=="update": update(); render()
    elif cmd=="backfill": backfill(int(sys.argv[2]) if len(sys.argv)>2 else 200)
    elif cmd=="render": render()
