#!/usr/bin/env bash
# test_wallet.sh v0.1 — AgentWallet policy-gate, MCP and quote tests. Uses a STUB signer and a throwaway
# policy directory: no real key, no broadcast. Network: read-only public RPC for balance/verify/quote.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; T="$(mktemp -d)"; fail=0
ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; fail=1; }
cleanup(){ [ -n "${DP:-}" ] && kill "$DP" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
# stub signer: echoes what it was asked, never touches a key
cat > "$T/signer-stub.mjs" <<'JS'
const [mode,to,amount,purpose]=process.argv.slice(2); if(mode==="send"&&Number(amount)===4.2){console.log(JSON.stringify({ok:false,mode,error:"stub: simulated broadcast failure",sent:false,stub:true}));process.exit(1);} console.log(JSON.stringify({ok:true,mode,to,amount:Number(amount),purpose,sent:mode==="send",stub:true}));
JS
cp "$HERE/policy.json" "$T/policy.json"; cp "$HERE/allowlist.json" "$T/allowlist.json"; cp "$HERE/approve.sh" "$T/approve.sh"; chmod +x "$T/approve.sh"
SOCK="$T/s.sock"; node "$HERE/signerd.mjs" --socket "$SOCK" --policy "$T/policy.json" --signer "$T/signer-stub.mjs" 2>"$T/signerd.log" & DP=$!; sleep 0.8
ask(){ printf '%s\n' "$1" | timeout 10 python3 -c '
import socket,sys,json; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.stdin.read().encode()); b=b""
while b"\n" not in b:
    d=s.recv(65536)
    if not d: break
    b+=d
print(b.decode().split("\n")[0])' "$SOCK"; }
A=0x1111111111111111111111111111111111111111
R=$(ask '{"op":"policy"}'); echo "$R" | grep -q '"allowlist_required": *true' && ok "1 policy op answers" || bad "1 policy: $R"
R=$(ask "{\"op\":\"quote\",\"to\":\"$A\",\"amount\":0.5,\"purpose\":\"test purpose long enough seq 1\"}"); echo "$R" | grep -q 'not in allowlist' && ok "2 quote refused: payee not allowlisted" || bad "2: $R"
"$T/approve.sh" allow $A 12345 "tester" >/dev/null && R=$(ask "{\"op\":\"quote\",\"to\":\"$A\",\"amount\":0.5,\"purpose\":\"test purpose long enough seq 1\"}"); echo "$R" | grep -q '"stub":true' && echo "$R" | grep -q '"sent":false' && ok "3 quote passes gate after allow (stub signer, nothing sent)" || bad "3: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":2.0,\"purpose\":\"test purpose long enough seq 1\"}"); echo "$R" | grep -q 'needs a human approval code' && ok "4 send 2.0 refused without approval code" || bad "4: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":0.5,\"purpose\":\"test purpose long enough seq 1\"}"); echo "$R" | grep -q '"sent":true' && ok "5 send 0.5 (below threshold) reaches the signer" || bad "5: $R"
CODE=$("$T/approve.sh" code $A 3 "tester" 1 | grep -oE 'code: [A-Za-z0-9]+' | cut -d' ' -f2)
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":2.0,\"purpose\":\"test purpose long enough seq 1\",\"approval\":\"$CODE\"}"); echo "$R" | grep -q '"sent":true' && ok "6 send 2.0 with one-time approval code" || bad "6: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":2.0,\"purpose\":\"test purpose long enough seq 1\",\"approval\":\"$CODE\"}"); echo "$R" | grep -q 'already used' && ok "7 approval code cannot be reused" || bad "7: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"0x2222222222222222222222222222222222222222\",\"amount\":2.0,\"purpose\":\"x\",\"approval\":\"$CODE\"}"); echo "$R" | grep -qE 'not in allowlist|different payee|already used' && ok "8 approval bound to payee" || bad "8: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":6,\"purpose\":\"test purpose long enough seq 1\"}"); echo "$R" | grep -q 'amount must be' && ok "9 per-tx cap in the gate" || bad "9: $R"
grep -q "not enforcement" "$T/signerd.log" && ok "10 daemon reports same-uid policy honestly" || bad "10 isolation report: $(cat "$T/signerd.log")"

# v0.3 (hardline-cto #14994)
R=$(ask "{\"op\":\"policy\"}"); echo "$R" | grep -q '"per_path"' && echo "$R" | grep -q '"approvals_dir"' && ok "15 isolation report is per path (policy, allowlist, approvals, budget, key, socket dir)" || bad "15: $R"
# budget: policy human_free_budget_per_day_usdt=2 in the throwaway policy; spent so far this test: 0.5 (test 5) -> 1.0 ok, 1.0 needs code
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":1.0,\"purpose\":\"split attack probe one seq 1\"}"); echo "$R" | grep -q '"sent":true' && ok "16a second below-threshold send within budget passes (spent 1.5/2)" || bad "16a: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":1.0,\"purpose\":\"split attack probe two seq 1\"}"); echo "$R" | grep -q 'needs a human approval code' && ok "16b splitting blocked: budget exhausted, 1.0 send needs a code" || bad "16b: $R"
# approval pending/used: a failing broadcast must NOT burn the code
CODE2=$("$T/approve.sh" code $A 5 "tester" 1 | grep -oE 'code: [A-Za-z0-9]+' | cut -d' ' -f2)
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":4.2,\"purpose\":\"failing broadcast probe seq 1\",\"approval\":\"$CODE2\"}"); echo "$R" | grep -q '"ok":false' && ok "17a failed broadcast reported as not sent" || bad "17a: $R"
grep -q '"released_at"' "$T/approvals/$CODE2.json" && ! grep -q '"used": true' "$T/approvals/$CODE2.json" && ok "17b approval released (not burned) after a failed broadcast" || bad "17b: $(cat "$T/approvals/$CODE2.json")"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":0.9,\"purpose\":\"retry after failure seq 1\",\"approval\":\"$CODE2\"}"); echo "$R" | grep -q '"sent":true' && grep -q '"used": true' "$T/approvals/$CODE2.json" && ok "17c same code works once after release, then marked used" || bad "17c: $R"
# purpose binding
CODE3=$("$T/approve.sh" code $A 1 "tester" 1 "pay for W-9 seq 777" | grep -oE 'code: [A-Za-z0-9]+' | cut -d' ' -f2)
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":0.9,\"purpose\":\"something else entirely 1\",\"approval\":\"$CODE3\"}"); echo "$R" | grep -q 'different purpose' && ok "18a purpose-bound code refuses another purpose" || bad "18a: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":0.9,\"purpose\":\"pay for W-9 seq 777\",\"approval\":\"$CODE3\"}"); echo "$R" | grep -q '"sent":true' && ok "18b purpose-bound code accepts the exact purpose" || bad "18b: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":\"NaN\",\"purpose\":\"nan probe seq 1\"}"); echo "$R" | grep -q 'finite number' && ok "19 NaN/string amounts refused" || bad "19: $R"
R=$(ask "{\"op\":\"send\",\"to\":\"$A\",\"amount\":0.000001,\"purpose\":\"dust probe seq 1\"}"); echo "$R" | grep -q 'below minimum' && ok "20 dust amounts refused (min 0.01)" || bad "20: $R"
python3 - "$T/budget.json" <<'PY2'
import json,sys,time
p=sys.argv[1]; b=json.load(open(p)); old=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()-25*3600))
b["entries"].append({"id":"old","at":old,"amount":1.5}); json.dump(b,open(p,"w"))
PY2
R=$(ask "{\"op\":\"policy\"}"); echo "$R" | grep -q '"human_free_sends_24h"' && ! echo "$R" | grep -q '"human_free_spent_24h_usdt":3' && ok "21 rolling window drops entries older than 24h (no UTC-midnight reset)" || bad "21: $R"
R=$(python3 -c '
import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"{\"op\":\"policy\",\"pad\":\""+b"A"*200000+b"\"}\n")
try:
    b=s.recv(65536); print(b.decode(errors="replace").split("\n")[0])
except Exception as e: print("closed:",e)' "$SOCK" 2>&1); echo "$R" | grep -qE 'too large|closed' && ok "22 oversized request (200 KB) refused, connection closed" || bad "22: $R"
R=$(ask '{"op":"policy"}'); echo "$R" | grep -q '"ok":true' && ok "23 daemon still serves after the oversized request" || bad "23: $R"
# mkwallet v0.3 (moth-under-glass #16304): key durable before the address exists; --address recovery
MW="$T/mw"; mkdir -p "$MW"; cp "$HERE/mkwallet.mjs" "$MW/"; ln -s "$HERE/node_modules" "$MW/node_modules" 2>/dev/null || ln -s "$HOME/.agent-link/signer/node_modules" "$MW/node_modules"
A24=$(cd "$MW" && AGENT_WALLET_DIR="$MW/w" node mkwallet.mjs 2>/dev/null); [ -f "$MW/w/PRIVATE_KEY.txt" ] && [ -f "$MW/w/ADDRESS.txt" ] && [ "$(stat -c %Y "$MW/w/PRIVATE_KEY.txt")" -le "$(stat -c %Y "$MW/w/ADDRESS.txt")" ] && [ ! -e "$MW/w/PRIVATE_KEY.txt.tmp" ] && ok "24 mkwallet: key landed before address, no tmp left" || bad "24: $(ls -la "$MW/w" 2>&1 | tr '\n' ' ')"
rm -f "$MW/w/ADDRESS.txt"; A24b=$(cd "$MW" && AGENT_WALLET_DIR="$MW/w" node mkwallet.mjs --address 2>/dev/null); [ "$A24b" = "$A24" ] && [ -f "$MW/w/ADDRESS.txt" ] && ok "25 mkwallet --address re-derives the same address from the key" || bad "25: got '$A24b' expected '$A24'"
(cd "$MW" && AGENT_WALLET_DIR="$MW/w" node mkwallet.mjs >/dev/null 2>&1); [ $? -eq 2 ] && ok "26 mkwallet refuses to overwrite an existing key (exit 2)" || bad "26: overwrite not refused"
printf 'garbage\n' > "$MW/w/ADDRESS.txt"; A27=$(cd "$MW" && AGENT_WALLET_DIR="$MW/w" node mkwallet.mjs --address 2>/dev/null); grep -q "^$A27$" "$MW/w/ADDRESS.txt" && [ "$A27" = "$A24" ] && ok "27 mkwallet post-condition: --address repairs a corrupted ADDRESS.txt from the key" || bad "27: $A27"
# MCP read-only
M=$(timeout 90 node "$HERE/mcp-client-test.mjs" 2>&1); echo "$M" | grep -q 'tools: wallet.address, wallet.balance, wallet.verify_tx, wallet.policy' && ok "11 MCP tools/list is read-only (4 tools)" || bad "11: $M"
echo "$M" | grep -E '^balance:' | grep -qE '"usdt":[0-9.]+,"eth":[0-9.e-]+,"outgoing_tx_count":[0-9]+,"is_contract":false' && ok "12 MCP wallet.balance via public RPC (shape + EOA)" || bad "12: $(echo "$M" | grep -E "^balance:" | head -c 300)"
echo "$M" | grep -q '"to_match":true' && echo "$M" | grep -q '"amount_match":true' && ok "13 MCP wallet.verify_tx matches payee and amount" || bad "13: $(echo "$M" | grep verify)"
# swap quote (read-only)
QD="$T/q"; mkdir -p "$QD"; cp "$HERE/swap_quote.mjs" "$QD/"; NM="$HERE/node_modules"; [ -d "$NM" ] || NM="$HOME/.agent-link/signer/node_modules"; ln -s "$NM" "$QD/node_modules"
Q=$(cd "$QD" && timeout 60 node swap_quote.mjs 1 50 2>&1 || true)
echo "$Q" | grep -q '"ok": true' && echo "$Q" | grep -q 'amount_out_weth' && ok "14 swap_quote: QuoterV2 answers for 1 USDT" || bad "14: $(echo "$Q" | head -c 300)"
echo "---"; [ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"; exit $fail
