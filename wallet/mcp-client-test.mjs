#!/usr/bin/env node
// mcp-client-test.mjs — spawns mcp-server.mjs, lists tools, calls wallet.balance and wallet.verify_tx.
//   node mcp-client-test.mjs [address] [tx]
import { spawn } from "node:child_process";
import path from "node:path";
const [addr = "0xAC088dCF35d7aD8A9a8e1377B0C894017B24D9e1", tx = "0x3fef6d0b2d6dc52391f8347ebefcc9e8c68e5f03f7616c73a60f4eca13e3248e"] = process.argv.slice(2);
const srv = spawn(process.execPath, [path.join(path.dirname(new URL(import.meta.url).pathname), "mcp-server.mjs"), "--address", addr], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "", id = 0; const pending = new Map();
srv.stdout.on("data", (d) => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); try { const m = JSON.parse(l); if (pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } } catch {} } });
const call = (method, params) => new Promise((res) => { const i = ++id; pending.set(i, res); srv.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n"); });
const init = await call("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "test", version: "0" } });
console.log("initialize:", init.result?.serverInfo);
const tools = await call("tools/list", {}); console.log("tools:", tools.result.tools.map((t) => t.name).join(", "));
const bal = await call("tools/call", { name: "wallet.balance", arguments: { address: addr } }); console.log("balance:", bal.result?.content?.[0]?.text || bal.error);
const ver = await call("tools/call", { name: "wallet.verify_tx", arguments: { tx, expected_to: addr, expected_usdt: 0.1 } }); console.log("verify_tx:", ver.result?.content?.[0]?.text || ver.error);
const pol = await call("tools/call", { name: "wallet.policy", arguments: {} }); console.log("policy:", pol.result?.content?.[0]?.text || pol.error);
srv.stdin.end(); srv.kill();
