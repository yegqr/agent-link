#!/usr/bin/env node
// signerd.mjs v0.1 — AgentWallet policy gate. A local daemon that OWNS the key and answers over a
// Unix socket; the agent never touches the key file. Layered on signer.mjs (caps, payee guard,
// ledger, receipts): signerd adds a root-ownable policy file, a payee ALLOWLIST with the board seq
// of the claimant's own post, and a HUMAN THRESHOLD: above it, a one-time approval code must exist in
// the approvals directory — written by the operator with approve.sh, never by the agent.
//
// Isolation (THREAT-MODEL.md C2): run this as a separate OS user (e.g. agentsigner) that owns the key,
// policy.json and approvals/; give the agent user only write access to the socket. On a single-user
// box it still runs, but then the policy is editable by the agent — the daemon says so on start.
//
//   node signerd.mjs [--socket PATH] [--policy PATH] [--signer PATH]
// Requests (one JSON per line):  {"op":"address"} | {"op":"balance"} | {"op":"quote","to":..,"amount":..,"purpose":..}
//                                {"op":"send","to":..,"amount":..,"purpose":..,"approval":"<code or absent>"}
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync } from "node:child_process";

const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf("--" + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const HERE = path.dirname(new URL(import.meta.url).pathname);
const SOCK = flag("socket", path.join(os.homedir(), ".agent-link", "signer", "signerd.sock"));
const POLICY = flag("policy", path.join(HERE, "policy.json"));
const SIGNER = flag("signer", path.join(HERE, "..", "signer.mjs"));
const APPROVALS = path.join(path.dirname(POLICY), "approvals");
const ALLOWLIST = path.join(path.dirname(POLICY), "allowlist.json");

function loadJson(p, fallback) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; } }
function policy() {
  const p = loadJson(POLICY, null);
  if (!p) throw new Error("policy.json missing or invalid: " + POLICY);
  return { max_per_tx: 5, max_per_day: 10, human_threshold_usdt: 1, allowlist_required: true, ...p };
}
function allowlist() { return loadJson(ALLOWLIST, { entries: [] }).entries || []; }
function isolationReport() {
  const me = os.userInfo().uid;
  const owner = (p) => { try { return fs.statSync(p).uid; } catch { return null; } };
  const same = [POLICY, ALLOWLIST].map(owner).every((u) => u === null || u === me);
  return { daemon_uid: me, policy_owner_uid: owner(POLICY), isolated: !same,
    note: same ? "policy files are owned by the daemon's own uid: caps are policy, not enforcement (THREAT-MODEL C2 not met)" : "policy files owned by another uid: C2 met" };
}
function checkApproval(code, to, amount) {
  if (!code || !/^[A-Za-z0-9_-]{8,64}$/.test(code)) return { ok: false, why: "approval code missing or malformed" };
  const f = path.join(APPROVALS, code + ".json");
  const a = loadJson(f, null);
  if (!a) return { ok: false, why: "approval not found" };
  if (a.used) return { ok: false, why: "approval already used" };
  if (String(a.to).toLowerCase() !== String(to).toLowerCase()) return { ok: false, why: "approval is for a different payee" };
  if (Number(a.max_usdt) < Number(amount)) return { ok: false, why: "approval max_usdt below requested amount" };
  if (a.expires_at && Date.now() > Date.parse(a.expires_at)) return { ok: false, why: "approval expired" };
  // consume: mark used (the agent cannot forge a new one if approvals/ is owned by another uid)
  try { fs.writeFileSync(f, JSON.stringify({ ...a, used: true, used_at: new Date().toISOString() }, null, 1)); } catch { return { ok: false, why: "cannot mark approval used" }; }
  return { ok: true, approved_by: a.approved_by, seq: a.board_seq };
}
function gate(req) {
  const p = policy();
  const to = String(req.to || ""), amount = Number(req.amount), purpose = String(req.purpose || "");
  if (!/^0x[0-9a-fA-F]{40}$/.test(to)) return { ok: false, error: "policy: bad address" };
  if (!(amount > 0) || amount > p.max_per_tx) return { ok: false, error: `policy: amount must be in (0, ${p.max_per_tx}]` };
  const entry = allowlist().find((e) => String(e.address).toLowerCase() === to.toLowerCase());
  if (p.allowlist_required && !entry) return { ok: false, error: "policy: payee not in allowlist (approve.sh allow <address> <board_seq>)" };
  let approval = null;
  if (amount > p.human_threshold_usdt) {
    const r = checkApproval(req.approval, to, amount);
    if (!r.ok) return { ok: false, error: "policy: above human threshold — " + r.why, human_threshold_usdt: p.human_threshold_usdt };
    approval = r;
  }
  return { ok: true, to, amount, purpose, allowlist_entry: entry || null, approval };
}
function runSigner(mode, to, amount, purpose) {
  const r = spawnSync(process.execPath, [SIGNER, mode, to, String(amount), purpose], { encoding: "utf8", timeout: 240000, env: { ...process.env, ABEL_PAYOUT_OK: mode === "send" ? "1" : "" } });
  let parsed = null; try { parsed = JSON.parse(r.stdout); } catch {}
  return { exit: r.status, signer: parsed || { raw: (r.stdout || "").slice(0, 2000), stderr: (r.stderr || "").slice(0, 500) } };
}
function handle(req) {
  const op = req.op;
  if (op === "address") return { ok: true, address: policy().treasury || null, isolation: isolationReport() };
  if (op === "policy") { const p = policy(); return { ok: true, policy: { max_per_tx: p.max_per_tx, max_per_day: p.max_per_day, human_threshold_usdt: p.human_threshold_usdt, allowlist_required: p.allowlist_required }, allowlist_size: allowlist().length, isolation: isolationReport() }; }
  if (op === "quote" || op === "send") {
    const g = gate(req); if (!g.ok) return { ...g, op };
    if (op === "quote") return { ok: true, op, gate: g, ...runSigner("quote", g.to, g.amount, g.purpose) };
    const r = runSigner("send", g.to, g.amount, g.purpose);
    return { ok: r.exit === 0, op, gate: { allowlist_seq: g.allowlist_entry && g.allowlist_entry.board_seq, approval: g.approval }, ...r };
  }
  return { ok: false, error: "unknown op" };
}
try { fs.unlinkSync(SOCK); } catch {}
fs.mkdirSync(path.dirname(SOCK), { recursive: true, mode: 0o700 });
const server = net.createServer((c) => {
  let buf = "";
  c.on("data", (d) => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); let req; try { req = JSON.parse(line); } catch { c.write(JSON.stringify({ ok: false, error: "bad json" }) + "\n"); continue; } let res; try { res = handle(req); } catch (e) { res = { ok: false, error: String(e.message || e) }; } c.write(JSON.stringify(res) + "\n"); } });
});
server.listen(SOCK, () => { try { fs.chmodSync(SOCK, 0o660); } catch {} const iso = isolationReport(); console.error(`[signerd] listening on ${SOCK}; policy ${POLICY}; ${iso.note}`); });
