#!/usr/bin/env node
// mcp-server.mjs v0.1 — AgentWallet MCP server over stdio (JSON-RPC 2.0, MCP 2024-11-05 shape).
// READ-ONLY by design at v0.1: wallet.address, wallet.balance, wallet.verify_tx, wallet.policy.
// wallet.send / wallet.swap are NOT exposed until THREAT-MODEL.md C2 (separate signer user) is met;
// the tool list says so. Zero dependencies; balances and receipts come from public JSON-RPC.
//   node mcp-server.mjs [--rpc URL] [--address 0x..] [--signer-socket PATH]
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf("--" + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const RPC = flag("rpc", "https://eth.drpc.org");
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const ADDR = flag("address", (() => { try { return fs.readFileSync(path.join(os.homedir(), ".agent-wallet", "ADDRESS.txt"), "utf8").trim(); } catch { return null; } })());
const SOCK = flag("signer-socket", path.join(os.homedir(), ".agent-link", "signer", "signerd.sock"));

const RPCS = [RPC, "https://ethereum-rpc.publicnode.com", "https://1rpc.io/eth", "https://eth.drpc.org"].filter((v, i, a) => a.indexOf(v) === i);
async function rpc(method, params) {
  let last = null;
  for (const url of RPCS) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(15000) });
      const j = await r.json(); if (j.error) { last = JSON.stringify(j.error); continue; } return j.result;
    } catch (e) { last = String(e.message || e); }
  }
  throw new Error("all RPCs failed: " + last);
}
const hex = (x) => BigInt(x);
async function balance(addr) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr || "")) throw new Error("bad address");
  const data = "0x70a08231" + addr.slice(2).toLowerCase().padStart(64, "0");
  const [u, e, n, c] = await Promise.all([rpc("eth_call", [{ to: USDT, data }, "latest"]), rpc("eth_getBalance", [addr, "latest"]), rpc("eth_getTransactionCount", [addr, "latest"]), rpc("eth_getCode", [addr, "latest"])]);
  return { address: addr, usdt: Number(hex(u)) / 1e6, eth: Number(hex(e)) / 1e18, outgoing_tx_count: Number(hex(n)), is_contract: c !== "0x", rpc: RPC, at: new Date().toISOString() };
}
async function verifyTx(tx, expectedTo, expectedUsdt) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(tx || "")) throw new Error("bad tx hash");
  const r = await rpc("eth_getTransactionReceipt", [tx]); if (!r) return { found: false, tx };
  const T = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  const xfers = (r.logs || []).filter((l) => l.address.toLowerCase() === USDT.toLowerCase() && (l.topics || [])[0] === T).map((l) => ({ from: "0x" + l.topics[1].slice(-40), to: "0x" + l.topics[2].slice(-40), usdt: Number(hex(l.data)) / 1e6 }));
  const out = { found: true, tx, status: Number(hex(r.status)), block: Number(hex(r.blockNumber)), usdt_transfers: xfers };
  if (expectedTo) out.to_match = xfers.some((x) => x.to.toLowerCase() === String(expectedTo).toLowerCase());
  if (expectedUsdt !== undefined) out.amount_match = xfers.some((x) => Math.round(x.usdt * 1e6) === Math.round(Number(expectedUsdt) * 1e6));
  return out;
}
function signerAsk(req) {
  return new Promise((resolve) => {
    const c = net.createConnection(SOCK); let buf = "";
    c.on("connect", () => c.write(JSON.stringify(req) + "\n"));
    c.on("data", (d) => { buf += d; if (buf.includes("\n")) { c.end(); try { resolve(JSON.parse(buf.split("\n")[0])); } catch { resolve({ ok: false, error: "bad reply" }); } } });
    c.on("error", (e) => resolve({ ok: false, error: "signerd unreachable: " + e.message }));
  });
}
const TOOLS = [
  { name: "wallet.address", description: "The agent's own receiving address (read-only).", inputSchema: { type: "object", properties: {} } },
  { name: "wallet.balance", description: "USDT and ETH balance of an address via a public RPC (read-only). Defaults to the agent's own address.", inputSchema: { type: "object", properties: { address: { type: "string" } } } },
  { name: "wallet.verify_tx", description: "Verify a USDT transfer by tx hash: status, block, transfers; optional expected payee and amount (read-only).", inputSchema: { type: "object", properties: { tx: { type: "string" }, expected_to: { type: "string" }, expected_usdt: { type: "number" } }, required: ["tx"] } },
  { name: "wallet.policy", description: "Spend policy and isolation status reported by signerd (read-only). wallet.send is not exposed at v0.1 — see THREAT-MODEL.md C2.", inputSchema: { type: "object", properties: {} } },
];
async function callTool(name, args = {}) {
  if (name === "wallet.address") return { address: ADDR };
  if (name === "wallet.balance") return balance(args.address || ADDR);
  if (name === "wallet.verify_tx") return verifyTx(args.tx, args.expected_to, args.expected_usdt);
  if (name === "wallet.policy") return signerAsk({ op: "policy" });
  throw new Error("unknown tool " + name);
}
function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", async (d) => {
  buf += d; let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    const id = m.id;
    try {
      if (m.method === "initialize") send({ jsonrpc: "2.0", id, result: { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "agentwallet", version: "0.1.0" } } });
      else if (m.method === "notifications/initialized") { /* no reply */ }
      else if (m.method === "tools/list") send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
      else if (m.method === "tools/call") { const r = await callTool(m.params?.name, m.params?.arguments || {}); send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(r) }] } }); }
      else if (m.method === "ping") send({ jsonrpc: "2.0", id, result: {} });
      else if (id !== undefined) send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
    } catch (e) { send({ jsonrpc: "2.0", id, error: { code: -32000, message: String(e.message || e) } }); }
  }
});
