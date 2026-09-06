#!/usr/bin/env node
// signerd.mjs v0.3.2 — AgentWallet policy gate. v0.3 answers hardline-cto #14994: a persisted HUMAN-FREE
// BUDGET per UTC day (splitting a payment into below-threshold sends no longer bypasses the human),
// per-path isolation report (policy, allowlist, approvals/, key file, socket dir), socket dir mode that a
// second uid can traverse, approvals marked pending -> used only after a successful broadcast, and
// approvals bound to a purpose string the human read before minting. v0.3.1 (hardline-cto #15061):
// the human-free budget is a ROLLING 24-hour window of timestamped sends, not a UTC-date bucket, so a
// send straddling midnight buys nothing; a minimum amount and a count cap stop dust probes. A local daemon that OWNS the key and answers over a
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
const BUDGET = path.join(path.dirname(POLICY), "budget.json"); // {"day":"YYYY-MM-DD","human_free_spent_usdt":n}
const KEYFILE_HINT = flag("keyfile", "/home/ye/PROJECTS/agent-space/wallet/PRIVATE_KEY.txt"); // reported, never read here

function loadJson(p, fallback) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; } }
function policy() {
  const p = loadJson(POLICY, null);
  if (!p) throw new Error("policy.json missing or invalid: " + POLICY);
  return { max_per_tx: 5, max_per_day: 10, human_threshold_usdt: 1, human_free_budget_per_day_usdt: 2, max_human_free_sends_per_day: 20, min_amount_usdt: 0.01, allowlist_required: true, ...p };
}
function allowlist() { return loadJson(ALLOWLIST, { entries: [] }).entries || []; }
function isolationReport() {
  const me = os.userInfo().uid;
  const owner = (p) => { try { return fs.statSync(p).uid; } catch { return null; } };
  const paths = { policy: POLICY, allowlist: ALLOWLIST, approvals_dir: APPROVALS, budget: BUDGET, key_file: KEYFILE_HINT, socket_dir: path.dirname(SOCK) };
  const per = {}; let allOther = true;
  for (const [k, p] of Object.entries(paths)) { const u = owner(p); per[k] = { path: p, owner_uid: u, other_uid: u !== null && u !== me }; if (u === null || u === me) allOther = false; }
  return { daemon_uid: me, per_path: per, isolated: allOther,
    note: allOther ? "every policy path, approvals/, the key file and the socket dir are owned by another uid: C2 met" : "at least one of policy/allowlist/approvals/budget/key/socket-dir is owned by the daemon's own uid or missing: caps are policy, not enforcement (THREAT-MODEL C2 not met)" };
}
const DAY_MS = 24 * 3600 * 1000;
function budgetLoad() { const b = loadJson(BUDGET, null); const now = Date.now(); const entries = (b && Array.isArray(b.entries) ? b.entries : []).filter((e) => now - Date.parse(e.at) < DAY_MS); return { entries, spent: Math.round(entries.reduce((s, e) => s + Number(e.amount), 0) * 1e6) / 1e6, count: entries.length }; }
function budgetSave(b) { fs.writeFileSync(BUDGET, JSON.stringify({ v: "rolling-24h/1", entries: b.entries })); }
function budgetRoom(amount) { const p = policy(); const b = budgetLoad(); return { ok: amount >= p.min_amount_usdt && b.spent + amount <= p.human_free_budget_per_day_usdt + 1e-9 && b.count < p.max_human_free_sends_per_day, spent: b.spent, count: b.count, budget: p.human_free_budget_per_day_usdt, window: "rolling 24h" }; }
function budgetReserve(amount) { const r = budgetRoom(amount); if (!r.ok) return r; const b = budgetLoad(); const id = Math.random().toString(36).slice(2); b.entries.push({ id, at: new Date().toISOString(), amount }); budgetSave(b); return { ...r, ok: true, spent: Math.round((r.spent + amount) * 1e6) / 1e6, id }; }
function budgetRelease(id) { const b = budgetLoad(); b.entries = b.entries.filter((e) => e.id !== id); try { budgetSave(b); } catch {} }
function approvalFile(code) { return (code && /^[A-Za-z0-9_-]{8,64}$/.test(code)) ? path.join(APPROVALS, code + ".json") : null; }
function checkApproval(code, to, amount, purpose) {
  const f = approvalFile(code); if (!f) return { ok: false, why: "approval code missing or malformed" };
  const a = loadJson(f, null);
  if (!a) return { ok: false, why: "approval not found" };
  if (a.used || a.pending) return { ok: false, why: a.used ? "approval already used" : "approval pending in another send" };
  if (String(a.to).toLowerCase() !== String(to).toLowerCase()) return { ok: false, why: "approval is for a different payee" };
  if (Number(a.max_usdt) < Number(amount)) return { ok: false, why: "approval max_usdt below requested amount" };
  if (a.expires_at && Date.now() > Date.parse(a.expires_at)) return { ok: false, why: "approval expired" };
  if (a.purpose && String(a.purpose) !== String(purpose)) return { ok: false, why: "approval bound to a different purpose string" };
  return { ok: true, file: f, approved_by: a.approved_by, seq: a.board_seq, purpose_bound: !!a.purpose };
}
function approvalMark(f, state) { const a = loadJson(f, null); if (!a) return; const now = new Date().toISOString(); const upd = state === "pending" ? { pending: true, pending_at: now } : state === "used" ? { pending: false, used: true, used_at: now } : { pending: false, released_at: now }; try { fs.writeFileSync(f, JSON.stringify({ ...a, ...upd }, null, 1)); } catch {} }
function gate(req) {
  const p = policy();
  const to = String(req.to || ""), amount = Number(req.amount), purpose = String(req.purpose || "");
  if (!/^0x[0-9a-fA-F]{40}$/.test(to)) return { ok: false, error: "policy: bad address" };
  if (!Number.isFinite(amount) || !(amount > 0) || amount > p.max_per_tx) return { ok: false, error: `policy: amount must be a finite number in (0, ${p.max_per_tx}]` };
  const entry = allowlist().find((e) => String(e.address).toLowerCase() === to.toLowerCase());
  if (p.allowlist_required && !entry) return { ok: false, error: "policy: payee not in allowlist (approve.sh allow <address> <board_seq>)" };
  // v0.3: below the per-request threshold the send still consumes the HUMAN-FREE daily budget; when the
  // budget is exhausted, every send needs a code, whatever its size. Splitting no longer bypasses the human.
  if (amount < p.min_amount_usdt) return { ok: false, error: `policy: amount below minimum ${p.min_amount_usdt} USDT` };
  const room = budgetRoom(amount); const withinBudget = amount <= p.human_threshold_usdt && room.ok;
  let approval = null;
  if (!withinBudget) {
    const r = checkApproval(req.approval, to, amount, purpose);
    if (!r.ok) return { ok: false, error: "policy: needs a human approval code — " + r.why, human_threshold_usdt: p.human_threshold_usdt, human_free_budget_per_day_usdt: p.human_free_budget_per_day_usdt, human_free_spent_24h_usdt: room.spent, human_free_sends_24h: room.count };
    approval = r;
  }
  return { ok: true, to, amount, purpose, allowlist_entry: entry || null, approval, consumes_budget: withinBudget };
}
function runSigner(mode, to, amount, purpose) {
  const r = spawnSync(process.execPath, [SIGNER, mode, to, String(amount), purpose], { encoding: "utf8", timeout: 240000, env: { ...process.env, ABEL_PAYOUT_OK: mode === "send" ? "1" : "" } });
  let parsed = null; try { parsed = JSON.parse(r.stdout); } catch {}
  return { exit: r.status, signer: parsed || { raw: (r.stdout || "").slice(0, 2000), stderr: (r.stderr || "").slice(0, 500) } };
}
function handle(req) {
  const op = req.op;
  if (op === "address") return { ok: true, address: policy().treasury || null, isolation: isolationReport() };
  if (op === "policy") { const p = policy(); const b = budgetLoad(); return { ok: true, policy: { max_per_tx: p.max_per_tx, max_per_day: p.max_per_day, human_threshold_usdt: p.human_threshold_usdt, human_free_budget_per_day_usdt: p.human_free_budget_per_day_usdt, max_human_free_sends_per_day: p.max_human_free_sends_per_day, min_amount_usdt: p.min_amount_usdt, allowlist_required: p.allowlist_required }, human_free_spent_24h_usdt: b.spent, human_free_sends_24h: b.count, allowlist_size: allowlist().length, isolation: isolationReport() }; }
  if (op === "quote" || op === "send") {
    const g = gate(req); if (!g.ok) return { ...g, op };
    if (op === "quote") return { ok: true, op, gate: g, ...runSigner("quote", g.to, g.amount, g.purpose) };
    let budget = null;
    if (g.consumes_budget) { budget = budgetReserve(g.amount); if (!budget.ok) return { ok: false, op, error: "policy: human-free daily budget exhausted; needs a human approval code", ...budget }; }
    if (g.approval) approvalMark(g.approval.file, "pending"); // v0.3: pending first, used only after a confirmed broadcast
    const r = runSigner("send", g.to, g.amount, g.purpose);
    const sent = r.exit === 0 || (r.signer && r.signer.sent === true);
    if (g.approval) approvalMark(g.approval.file, sent ? "used" : "released");
    if (g.consumes_budget && !sent && budget && budget.id) budgetRelease(budget.id);
    return { ok: sent, op, gate: { allowlist_seq: g.allowlist_entry && g.allowlist_entry.board_seq, approval: g.approval ? { approved_by: g.approval.approved_by, purpose_bound: g.approval.purpose_bound } : null, human_free_budget: budget }, ...r };
  }
  return { ok: false, error: "unknown op" };
}
try { fs.unlinkSync(SOCK); } catch {}
// v0.3: the socket dir must be traversable by the AGENT uid when C2 separates the users: 0750 + a shared
// group (e.g. `agentwallet`) that the agent user belongs to; the socket itself stays 0660 (group rw).
fs.mkdirSync(path.dirname(SOCK), { recursive: true, mode: 0o750 });
try { fs.chmodSync(path.dirname(SOCK), 0o750); } catch {}
const server = net.createServer((c) => {
  let buf = "";
  c.on("data", (d) => { buf += d; if (buf.length > 65536) { c.write(JSON.stringify({ ok: false, error: "request too large (64 KiB line cap)" }) + "\n"); c.destroy(); return; } // v0.3.2 (cain #15180): bounded buffer
    let i; while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); let req; try { req = JSON.parse(line); } catch { c.write(JSON.stringify({ ok: false, error: "bad json" }) + "\n"); continue; } let res; try { res = handle(req); } catch (e) { res = { ok: false, error: String(e.message || e) }; } c.write(JSON.stringify(res) + "\n"); } });
});
server.listen(SOCK, () => { try { fs.chmodSync(SOCK, 0o660); } catch {} const iso = isolationReport(); console.error(`[signerd] listening on ${SOCK}; policy ${POLICY}; ${iso.note}`); });
