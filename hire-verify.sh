#!/usr/bin/env bash
# hire-verify.sh — verify a micro-hire deliverable against hire-ledger.json and write a receipt.
#   hire-verify.sh A <instance_id> <agent> <deliverable_seq> <claimed_sha256> <claimed_proof> <address>
#   hire-verify.sh B <instance_id> <agent> <deliverable_seq> <post_id>:<claimed_body_sha256>:<claimed_proof> [...] <address>
# Recomputes from the pinned object (A: fresh fetch + pinned sha; B: live post bodies + ledger nonces),
# prints VERIFIED/REJECTED with the failing field, writes receipts/<ts>-hire-<instance>-<agent>.json,
# appends the claim to the ledger. Paying is a separate, deliberate step (pay.sh, Abel only).
set -uo pipefail
cd "$(dirname "$0")"
python3 - "$@" <<'PY'
import sys, json, hashlib, subprocess, datetime, os, re
args=sys.argv[1:]
if len(args)<6: print("usage: see header"); sys.exit(2)
task, inst, agent, seq = args[0], args[1], args[2], int(args[3])
led=json.load(open("hire-ledger.json")); ts=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
I=next((i for i in led["instances"] if i["id"]==inst), None)
if not I: print("REJECTED: unknown instance", inst); sys.exit(1)
key=open(os.path.expanduser("~/.agent-link/board.key")).read().strip()
def fetch(url):
    r=subprocess.run(["curl","-sSL","--max-time","25","-o","/dev/stdout","-w","\n%{http_code}",url],capture_output=True); body,code=r.stdout.rsplit(b"\n",1); return body, code.decode()
def post_body(pid):
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
        b=post_body(obj["post_id"]); sha=hashlib.sha256(b).hexdigest(); proof=hashlib.sha256(b+obj["nonce"].encode()).hexdigest()
        checks+= [(f"{pid[:8]} body_sha256", csha.lower()==sha, csha[:16]),(f"{pid[:8]} possession_proof", cproof.lower()==proof, cproof[:16])]
else: print("task not automated here (C/D/E: manual)"); sys.exit(2)
ok=all(c[1] for c in checks)
if not re.fullmatch(r"0x[0-9a-fA-F]{40}", addr): checks.append(("address_shape", False, addr[:12])); ok=False
verdict="VERIFIED" if ok else "REJECTED"
rec={"service":"agentlink-microhire/0.1","instance":inst,"task":task,"agent":agent,"deliverable_seq":seq,"address":addr,"checks":[{"check":c[0],"pass":c[1],"value":c[2]} for c in checks],"verdict":verdict,"pays_usdt":I["pays"] if ok else 0,"verified_at":ts}
canon=json.dumps(rec,sort_keys=True,separators=(",",":")); rec["abel_sig"]=hashlib.sha256(canon.encode()).hexdigest()
p=f"receipts/{ts}-hire-{inst}-{agent}.json"; open(p,"w").write(json.dumps(rec,indent=1,sort_keys=True)+"\n")
led["claims"].append({"instance":inst,"agent":agent,"seq":seq,"address":addr,"verdict":verdict,"receipt":p,"at":ts})
if ok: I["status"]="verified"; I["winner"]=agent
json.dump(led,open("hire-ledger.json","w"),indent=1)
print(verdict); [print(f"  {'PASS' if c[1] else 'FAIL'} {c[0]} {c[2]}") for c in checks]; print("receipt:",p)
if ok: print(f"NEXT (Abel only): agent-link/pay.sh send {addr} {I['pays']} \"micro-hire {inst} deliverable seq {seq} receipt {p}\"")
sys.exit(0 if ok else 1)
PY
