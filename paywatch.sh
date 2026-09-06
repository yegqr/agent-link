#!/usr/bin/env bash
# paywatch.sh — incoming-payment watcher for the AgentLink treasury. READ-ONLY.
# Talks to public Ethereum RPCs only; needs no key, holds no key, signs nothing.
#   paywatch.sh balance                 ETH + USDT balance of the treasury
#   paywatch.sh verify <txhash> [min]   verify a claimed USDT payment (ERC-20 Transfer
#                                       to the treasury), emit a receipt JSON
#   paywatch.sh scan [blocks]           list incoming USDT transfers in the last N blocks
#                                       (default 7200 ~ 1 day), emit a receipt JSON
# Receipts: receipts/<UTCts>-pay-<verify|scan>-<id>.json, abel_sig = sha256 of the
# canonical body (sort_keys, no spaces) without abel_sig.
set -uo pipefail
cd "$(dirname "$0")"
ADDR="${TREASURY:-0x9b349A3bc383c2CD752aF69e856e671F8E10a030}"
USDT="0xdAC17F958D2ee523a2206206994597C13D831ec7"
exec python3 - "$@" <<'PY'
import sys, json, hashlib, datetime, os, subprocess, time, re, math
ADDR=os.environ.get("TREASURY","0x9b349A3bc383c2CD752aF69e856e671F8E10a030"); USDT="0xdAC17F958D2ee523a2206206994597C13D831ec7"
def need_tx(s):
    # fail-closed BEFORE any RPC: txhash must be 0x + 64 hex chars (v0.1.1 argv pre-validation)
    if not isinstance(s,str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}",s):
        print("usage: paywatch.sh verify <0x + 64-hex txhash> [min_usdt]"); sys.exit(2)
    return s
def need_min(s):
    try: m=float(s)
    except Exception: print("usage: [min_usdt] must be a finite number >= 0"); sys.exit(2)
    if not math.isfinite(m) or m<0: print("usage: [min_usdt] must be a finite number >= 0"); sys.exit(2)
    return m
def need_span(s):
    try: n=int(s)
    except Exception: print("usage: [blocks] must be an integer 1..2000000"); sys.exit(2)
    if not 1<=n<=2_000_000: print("usage: [blocks] must be an integer 1..2000000"); sys.exit(2)
    return n
TRANSFER="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
RPCS=["https://ethereum-rpc.publicnode.com","https://cloudflare-eth.com","https://rpc.flashbots.net","https://1rpc.io/eth"]
LOG_RPCS=["https://cloudflare-eth.com","https://rpc.flashbots.net"]   # eth_getLogs: cloudflare max 800-block windows (measured 2026-09-06)
LOG_STEP=800
def rpc(method, params):
    body=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params})
    last=None
    for u in (LOG_RPCS if method=="eth_getLogs" else RPCS):
        r=subprocess.run(["curl","-sS","--max-time","25","-H","content-type: application/json","--data",body,u],capture_output=True,text=True)
        try:
            d=json.loads(r.stdout)
            if "result" in d and d["result"] is not None: return d["result"], u
            last=d.get("error") or "null result"
        except Exception as e: last=str(e)
    raise SystemExit(f"FAIL: rpc {method}: {last}")
def ts(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
def pad(a): return "0x"+a[2:].lower().rjust(64,"0")
def seal(r):
    canon=json.dumps(r,sort_keys=True,separators=(",",":")); r["abel_sig"]=hashlib.sha256(canon.encode()).hexdigest(); return r
def save(kind, ident, r):
    os.makedirs("receipts",exist_ok=True); p=f"receipts/{ts()}-pay-{kind}-{ident}.json"
    open(p,"w").write(json.dumps(r,indent=1,sort_keys=True)+"\n"); return p
cmd=sys.argv[1] if len(sys.argv)>1 else "balance"
if cmd=="balance":
    eth,_=rpc("eth_getBalance",[ADDR,"latest"]); data="0x70a08231"+ADDR[2:].lower().rjust(64,"0")
    usdt,u=rpc("eth_call",[{"to":USDT,"data":data},"latest"])
    print(json.dumps({"address":ADDR,"eth":int(eth,16)/1e18,"usdt":int(usdt,16)/1e6,"rpc":u,"at":ts()}))
elif cmd=="verify":
    tx=need_tx(sys.argv[2] if len(sys.argv)>2 else ""); minimum=need_min(sys.argv[3]) if len(sys.argv)>3 else 0.0
    rec,u=rpc("eth_getTransactionReceipt",[tx]); latest,_=rpc("eth_blockNumber",[])
    blk=int(rec["blockNumber"],16); conf=int(latest,16)-blk+1
    hits=[]
    for lg in rec.get("logs",[]):
        if lg["address"].lower()==USDT.lower() and lg["topics"][0]==TRANSFER and lg["topics"][2].lower()==pad(ADDR):
            hits.append({"from":"0x"+lg["topics"][1][-40:],"to":ADDR,"amount_usdt":int(lg["data"],16)/1e6,"log_index":int(lg["logIndex"],16)})
    total=sum(h["amount_usdt"] for h in hits); ok=rec.get("status")=="0x1" and total>0 and total>=minimum and conf>=1
    r={"service":"agentlink-pay/0.1.1","kind":"verify","tx":tx,"block":blk,"confirmations":conf,"status_ok":rec.get("status")=="0x1",
       "transfers_to_treasury":hits,"total_usdt":total,"minimum_required_usdt":minimum,"verified":ok,"treasury":ADDR,"token":"USDT (ERC-20) "+USDT,
       "rpc":u,"verified_at":ts(),"limits":"read-only public RPC; confirms an on-chain transfer to the treasury, nothing about who the sender is off-chain"}
    p=save("verify",tx[2:10],seal(r)); print(json.dumps(r,indent=1,sort_keys=True)); print("receipt:",p); sys.exit(0 if ok else 1)
elif cmd=="scan":
    # Primary: Blockscout public indexer (no key). Public RPCs measured 2026-09-06 either
    # refuse eth_getLogs (publicnode: archive token; 1rpc: 50-block cap) or error on
    # topic filters (cloudflare: -32603). Fallback: RPC getLogs in LOG_STEP windows.
    span=need_span(sys.argv[2]) if len(sys.argv)>2 else 7200
    latest,_=rpc("eth_blockNumber",[]); L=int(latest,16); start=L-span; found=[]; src=None
    r0=subprocess.run(["curl","-sS","--max-time","25",f"https://eth.blockscout.com/api/v2/addresses/{ADDR}/token-transfers?type=ERC-20&filter=to"],capture_output=True,text=True)
    try:
        items=json.loads(r0.stdout).get("items",[]); src="https://eth.blockscout.com (indexer)"
        for t in items:
            tok=t.get("token",{}) or {}; taddr=(tok.get("address") or tok.get("address_hash") or "").lower()
            if taddr!=USDT.lower() and tok.get("symbol")!="USDT": continue
            if (t.get("to",{}).get("hash") or "").lower()!=ADDR.lower(): continue
            if t.get("block_number",0)<start: continue
            found.append({"tx":t["transaction_hash"],"block":t["block_number"],"time":t.get("timestamp"),"from":t.get("from",{}).get("hash"),"amount_usdt":int(t["total"]["value"])/10**int(t["total"].get("decimals",6))})
    except Exception:
        src=None
    if src is None:
        b=start; step=LOG_STEP
        while b<=L-2:
            e=min(b+step-1,L-2)
            logs,src=rpc("eth_getLogs",[{"fromBlock":hex(b),"toBlock":hex(e),"address":USDT,"topics":[TRANSFER,None,pad(ADDR)]}])
            for lg in logs:
                found.append({"tx":lg["transactionHash"],"block":int(lg["blockNumber"],16),"from":"0x"+lg["topics"][1][-40:],"amount_usdt":int(lg["data"],16)/1e6})
            b=e+1
    r={"service":"agentlink-pay/0.1.1","kind":"scan","treasury":ADDR,"token":"USDT (ERC-20) "+USDT,"from_block":start,"to_block":L,"incoming":found,
       "total_usdt":sum(x["amount_usdt"] for x in found),"count":len(found),"source":src,"scanned_at":ts(),
       "limits":"indexer/RPC read-only; an incoming transfer proves money arrived, not who sent it or why — the board reply naming the tx is the link"}
    p=save("scan",f"{start}-{L}",seal(r)); print(json.dumps(r,indent=1,sort_keys=True)); print("receipt:",p)
elif cmd=="watch":
    # cron mode: scan, diff against .paywatch-seen, print ONLY new incoming transfers
    # (one JSON line each) and append them to LOG.md via log-append.sh. Exit 0 always.
    import io
    seenf=".paywatch-seen"; seen=set(open(seenf).read().split()) if os.path.exists(seenf) else set()
    out=subprocess.run(["bash","paywatch.sh","scan",str(need_span(sys.argv[2]) if len(sys.argv)>2 else 7200)],capture_output=True,text=True).stdout
    try:
        import re; d=json.loads(re.search(r"\{.*\}",out,re.S).group(0))
    except Exception:
        print("watch: scan failed"); sys.exit(0)
    new=[x for x in d["incoming"] if x["tx"] not in seen]
    for x in new:
        line=f'{ts()} | PAYWATCH: incoming {x["amount_usdt"]:.6f} USDT tx {x["tx"]} block {x["block"]} from {x["from"]} (unclaimed until a board reply names the tx; receipt via paywatch.sh verify). Stopping.'
        subprocess.run(["bash","log-append.sh","../LOG.md","--",line]); print(json.dumps(x))
    open(seenf,"w").write("\n".join(sorted(seen|{x["tx"] for x in d["incoming"]}))+"\n")
    print(f"watch: {len(new)} new, {len(d['incoming'])} total in window")
else:
    print("usage: paywatch.sh balance|verify <tx> [min]|scan [blocks]|watch [blocks]"); sys.exit(2)
PY
