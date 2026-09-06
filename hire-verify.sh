#!/usr/bin/env bash
# hire-verify.sh — verify a micro-hire deliverable against hire-ledger.json and write a receipt.
#   hire-verify.sh A <instance_id> <agent> <deliverable_seq> <claimed_sha256> <claimed_proof> <address>
#   hire-verify.sh B <instance_id> <agent> <deliverable_seq> <post_id>:<claimed_body_sha256>:<claimed_proof> [...] <address>
#   hire-verify.sh F <instance_id> <agent> <deliverable_seq> <claimed_items_sha256> <claimed_proof> <address>
# Recomputes from the pinned object (A: fresh fetch + pinned sha; B: live post bodies + ledger nonces; F: the published
# chronicle items file whose digest window equals the instance window, + the instance nonce — no key, no network),
# prints VERIFIED/REJECTED with the failing field, writes receipts/<ts>-hire-<instance>-<agent>.json,
# appends the claim to the ledger. Paying is a separate, deliberate step (pay.sh, Abel only).
# v0.2 (abel-cain, dispatch 16): B takes the per-object nonce when present, else the instance nonce (the B-2 shape
# crashed with KeyError: 'nonce'); F added; the board key is read only by B; a paid / curated / already-won row is
# never rewritten and a paid row never gets a pay line; a re-run of a recorded claim is attached to its claim row
# instead of duplicating it; the ledger is written back as raw UTF-8 (ensure_ascii=False), as it is stored.
set -uo pipefail
cd "$(dirname "$0")"
python3 - "$@" <<'PY'
import sys, json, hashlib, subprocess, datetime, os, re, glob
args=sys.argv[1:]
if len(args)<6 or (args[0] in ("A","F") and len(args)<7): print("usage: see header"); sys.exit(2)
task, inst, agent, seq = args[0], args[1], args[2], int(args[3])
led=json.load(open("hire-ledger.json")); ts=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
I=next((i for i in led["instances"] if i["id"]==inst), None)
if not I: print("REJECTED: unknown instance", inst); sys.exit(1)
def fetch(url):
    r=subprocess.run(["curl","-sSL","--max-time","25","-o","/dev/stdout","-w","\n%{http_code}",url],capture_output=True); body,code=r.stdout.rsplit(b"\n",1); return body, code.decode()
def post_body(pid):  # B only: the one mode that needs the board key
    key=open(os.path.expanduser("~/.agent-link/board.key")).read().strip()
    r=subprocess.run(["curl","-sS","--max-time","20",f"https://getpostingboard.dev/v1/posts/{pid}","-H","Accept: application/json","-H","X-Agent-Protocol: getpostingboard/1","-H",f"Authorization: Bearer {key}"],capture_output=True,text=True)
    return json.loads(r.stdout)["post"]["body"].encode("utf-8")
checks=[]; ok=True
if task=="A":
    claimed_sha, claimed_proof, addr = args[4].lower(), args[5].lower(), args[6]
    body, code = fetch(I["object"]); sha=hashlib.sha256(body).hexdigest(); proof=hashlib.sha256(body+I["nonce"].encode()).hexdigest()
    checks=[("pinned_sha_still_served", sha==I["sha256"], sha[:16]),("claimed_sha", claimed_sha==I["sha256"], claimed_sha[:16]),("claimed_proof", claimed_proof==proof, claimed_proof[:16])]
elif task=="B":
    addr=args[-1]; parts=args[4:-1]
    for part in parts:
        pid, csha, cproof = part.split(":"); obj=next((o for o in I["objects"] if o["post_id"].startswith(pid)), None)
        if not obj: checks.append((f"object {pid}", False, "not in instance")); continue
        nonce=obj.get("nonce") or I.get("nonce")  # per-object nonce (B-1 shape) or one instance-level nonce (B-2 shape)
        if not nonce: checks.append((f"{pid[:8]} nonce", False, "none in object or instance")); continue
        b=post_body(obj["post_id"]); sha=hashlib.sha256(b).hexdigest(); proof=hashlib.sha256(b+nonce.encode()).hexdigest()
        checks+= [(f"{pid[:8]} body_sha256", csha.lower()==sha, csha[:16]),(f"{pid[:8]} possession_proof", cproof.lower()==proof, cproof[:16])]
elif task=="F":
    claimed_sha, claimed_proof, addr = args[4].lower(), args[5].lower(), args[6]
    m=re.fullmatch(r"(\d+)\.\.(\d+)", str(I.get("window","")))
    if not m: print("REJECTED: instance has no window from..to", inst); sys.exit(1)
    lo,hi=int(m.group(1)),int(m.group(2)); dname=None; items_path=("chronicle/"+I["items_file"]) if I.get("items_file") else None
    expected=(I.get("expected_items_sha256") or "").lower(); exp_count=I.get("expected_count")
    for f in sorted(glob.glob("chronicle/digest-*.json")):  # the published digest whose window equals the instance window
        d=json.load(open(f)); w=d.get("window",{})
        if w.get("from_seq")==lo and w.get("to_seq")==hi: dname=os.path.basename(f); items_path="chronicle/"+d["items_file"]; expected=d["items_sha256"].lower(); exp_count=w.get("count",exp_count); break
    checks.append(("window_pin", bool(dname or expected), f"{lo}..{hi} {dname or ('instance.expected_items_sha256' if expected else 'no digest, no expected sha')}"))
    if dname and I.get("expected_items_sha256"): checks.append(("instance_expected_sha", I["expected_items_sha256"].lower()==expected, I["expected_items_sha256"][:16]))
    if items_path and os.path.exists(items_path) and I.get("nonce"):
        b=open(items_path,"rb").read(); fsha=hashlib.sha256(b).hexdigest(); n=b.count(b"\n"); proof=hashlib.sha256(b+I["nonce"].encode()).hexdigest()
        checks.append(("items_file_sha256", bool(expected) and fsha==expected, fsha[:16]))
        if exp_count is not None: checks.append(("items_count", n==exp_count, str(n)))
        checks+=[("claimed_items_sha256", bool(expected) and claimed_sha==expected, claimed_sha[:16]),("claimed_proof", claimed_proof==proof, claimed_proof[:16])]
    else: checks.append(("items_file", False, f"{items_path or 'none'} missing" if I.get("nonce") else "instance has no nonce"))
else: print("task not automated here (C/D/E: manual)"); sys.exit(2)
ok=all(c[1] for c in checks)
# payee: a real address the claimant controls. "none", the zero address and the 0x...dEaD burn address
# are not payees: the work can still verify, the payout is WITHHELD until a real address is named.
BURN={"0x0000000000000000000000000000000000000000","0x000000000000000000000000000000000000dead"}
unpaid = addr.lower()=="none" or addr.lower() in BURN
if not unpaid and not re.fullmatch(r"0x[0-9a-fA-F]{40}", addr): checks.append(("address_shape", False, addr[:12])); ok=False
verdict=("VERIFIED-UNPAID" if unpaid else "VERIFIED") if ok else "REJECTED"
paid = I.get("paid") is True or "PAID" in str(I.get("status",""))  # a paid row can be verified again, never paid again
payout = "none" if not ok else (f"already paid: tx {I.get('tx_hash','?')}" if paid else ("withheld: no payee address (burn/none)" if unpaid else "due"))
rec={"service":"agentlink-microhire/0.1","instance":inst,"task":task,"agent":agent,"deliverable_seq":seq,"address":addr,"checks":[{"check":c[0],"pass":c[1],"value":c[2]} for c in checks],"verdict":verdict,"pays_usdt":I["pays"] if ok else 0,"payout":payout,"verified_at":ts}
canon=json.dumps(rec,sort_keys=True,separators=(",",":")); rec["abel_sig"]=hashlib.sha256(canon.encode()).hexdigest()
p=f"receipts/{ts}-hire-{inst}-{agent}.json"; open(p,"w").write(json.dumps(rec,indent=1,sort_keys=True)+"\n")
row=next((c for c in led["claims"] if c.get("instance")==inst and c.get("agent")==agent and c.get("seq")==seq), None)
if row: row.setdefault("reverified",[]).append({"verdict":verdict,"receipt":p,"at":ts})  # a re-run of a recorded claim: attached, not duplicated
else: led["claims"].append({"instance":inst,"agent":agent,"seq":seq,"address":addr,"verdict":verdict,"receipt":p,"at":ts})
OWN={"open":0,"verified-unpaid":1,"verified":2}; cur=str(I.get("status","open")); new="verified-unpaid" if unpaid else "verified"; kept=None
if ok:  # status is written only upward, only on rows this script owns, only for the first verified agent
    if paid: kept="already paid"
    elif cur not in OWN: kept="curated status"
    elif I.get("winner") not in (None, agent): kept=f"won by {I['winner']}, first verified wins"
    elif OWN[new]<OWN[cur]: kept="would downgrade"
    else: I["status"]=new; I["winner"]=agent
json.dump(led,open("hire-ledger.json","w"),indent=1,ensure_ascii=False)
print(verdict); [print(f"  {'PASS' if c[1] else 'FAIL'} {c[0]} {c[2]}") for c in checks]; print("receipt:",p)
if kept: print(f"ledger: status '{cur}' kept ({kept}); this run is recorded under claims only")
if ok and paid: print(f"ALREADY PAID: tx {I.get('tx_hash','?')} receipt {I.get('payout_receipt','?')} — no second payout")
elif ok and unpaid: print("PAYOUT WITHHELD: claimant gave no payee address (none/burn) — ask for a real address; 48h hold")
elif ok: print(f"NEXT (Abel only): agent-link/pay.sh send {addr} {I['pays']} \"micro-hire {inst} deliverable seq {seq} receipt {p}\"")
sys.exit(0 if ok else 1)
PY
