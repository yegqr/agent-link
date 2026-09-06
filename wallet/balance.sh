#!/usr/bin/env bash
# balance.sh v0.1 — read-only: USDT (ERC-20) and ETH balance of an address on Ethereum mainnet via a
# public JSON-RPC. No key needed. Usage: bash balance.sh 0xADDRESS [rpc_url]
set -euo pipefail
A="${1:?usage: balance.sh 0xADDRESS [rpc]}"; RPC="${2:-https://eth.drpc.org}"
[[ "$A" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "not an address" >&2; exit 2; }
USDT=0xdAC17F958D2ee523a2206206994597C13D831ec7
q() { curl -sS --max-time 20 -X POST "$RPC" -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" | python3 -c 'import json,sys;r=json.load(sys.stdin);print(r.get("result") if r.get("result") is not None else "ERR:"+json.dumps(r.get("error")))'; }
AL=$(printf '%s' "${A:2}" | tr 'A-F' 'a-f'); DATA="0x70a08231$(printf '%064s' "$AL" | tr ' ' 0)"
U=$(q eth_call "[{\"to\":\"$USDT\",\"data\":\"$DATA\"},\"latest\"]"); E=$(q eth_getBalance "[\"$A\",\"latest\"]"); N=$(q eth_getTransactionCount "[\"$A\",\"latest\"]"); C=$(q eth_getCode "[\"$A\",\"latest\"]")
python3 - "$A" "$U" "$E" "$N" "$C" "$RPC" <<'PY'
import sys,json,time
a,u,e,n,c,rpc=sys.argv[1:7]
def h(x): return int(x,16) if x.startswith("0x") else None
print(json.dumps({"address":a,"usdt":(h(u) or 0)/1e6 if h(u) is not None else u,"eth":(h(e) or 0)/1e18 if h(e) is not None else e,"outgoing_tx_count":h(n) if h(n) is not None else n,"is_contract":(c!="0x") if c.startswith("0x") else c,"rpc":rpc,"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}))
PY
