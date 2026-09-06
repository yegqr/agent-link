#!/usr/bin/env node
// signer-ledger-test.mjs v0.1 — CAIN dispatch 21 (2026-09-06): standalone harness for the daily-cap
// ledger accounting of signer.mjs v0.2.1 (the fix for #15457/#15465/#15484: three ledger lines per
// transfer were summed, 3.30 USDT read as 9.90). Does NOT import signer.mjs — it has fixed paths, a
// key read, RPC calls and ledger writes. The block between BEGIN/END VERBATIM is a byte copy of
// signer.mjs lines 25, 40 and 44 (sha256 245b84f0b260f0916280ca6469f246a80f0177e0ef4f45014596370aa8abfa5f);
// `--verify-verbatim` re-checks that every copied line still appears verbatim in the signer, so drift
// fails loudly instead of testing a stale copy.
//   node signer-ledger-test.mjs <ledger.jsonl>                  -> JSON: ledger_today over that file (today = real UTC date)
//   node signer-ledger-test.mjs --cases [dir]                   -> writes synthetic ledgers into dir (default: a fresh tmpdir),
//                                                                 evaluates each, prints PASS/GAP/FAIL, exit 1 on any FAIL
//   node signer-ledger-test.mjs --verify-verbatim <signer.mjs>  -> exit 0 iff the copied lines are byte-identical in the signer
// No network, no key, no real ledger: the only files read are the argv path / the fixtures this file writes.
// Verdicts: PASS = actual == safe expectation; GAP = actual == what v0.2.1 is predicted to do, but that is not the
// safe value (a finding, not a harness failure); FAIL = the prediction itself is wrong (look at the harness).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

function evalLedgerToday(LEDGER) {
// BEGIN VERBATIM (signer.mjs v0.2.1 lines 25, 40, 44 — do not edit; --verify-verbatim checks these against the signer)
const today = () => new Date().toISOString().slice(0, 10);
function ledgerLines() { try { return fs.readFileSync(LEDGER, "utf8").split("\n").filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean); } catch { return []; } }
const ledgerToday = (() => { const byNonce = new Map(); for (const l of ledgerLines()) { if ((l.at || "").slice(0, 10) !== today()) continue; const k = String(l.nonce ?? l.at); const prev = byNonce.get(k); if (!prev || String(l.at) >= String(prev.at)) byNonce.set(k, l); } let s = 0; for (const l of byNonce.values()) if (l.status !== "broadcast_failed") s += Number(l.amount_usdt || 0); return s; })();
// END VERBATIM
return ledgerToday;
}

const SELF = fileURLToPath(import.meta.url);
const utcDay = () => new Date().toISOString().slice(0, 10);
const r2 = (x) => Math.round(x * 100) / 100;

// The verbatim block as text (for --verify-verbatim and for the mutation checks).
function verbatimBlock() {
  const lines = fs.readFileSync(SELF, "utf8").split("\n");
  const b = lines.findIndex(l => l.startsWith("// BEGIN VERBATIM")), e = lines.findIndex(l => l.startsWith("// END VERBATIM"));
  if (b < 0 || e < 0 || e <= b) throw new Error("verbatim markers missing");
  return lines.slice(b + 1, e).filter(l => l.trim() && !l.startsWith("//"));
}
function mutant(replacements) {
  let src = verbatimBlock().join("\n");
  for (const [from, to] of replacements) { if (!src.includes(from)) throw new Error("mutation target not found: " + from); src = src.split(from).join(to); }
  return new Function("fs", "LEDGER", src + "\nreturn ledgerToday;");
}

// Instrumentation outside the verbatim block: raw vs parsed line counts and the v0.2 sum-every-line figure.
function inspect(LEDGER) {
  const raw = fs.readFileSync(LEDGER, "utf8").split("\n").filter(Boolean);
  const parsed = raw.map(l => { try { return JSON.parse(l); } catch { return null; } });
  const todayLines = parsed.filter(l => l && (l.at || "").slice(0, 10) === utcDay());
  return {
    lines_raw: raw.length, lines_unparseable: parsed.filter(l => !l).length,
    lines_today: todayLines.length, lines_today_without_at: parsed.filter(l => l && !l.at).length,
    v0_2_sum_all_today: r2(todayLines.reduce((s, l) => s + Number(l.amount_usdt || 0), 0)),
    keys_today: [...new Set(todayLines.map(l => String(l.nonce ?? l.at)))],
  };
}

// ---- synthetic ledger lines shaped exactly like signer.mjs writes them (lines 92, 96, 99, 104) ----
const TO = "0x1111111111111111111111111111111111111111", PURPOSE = "synthetic ledger line, cites seq 0 and receipt none";
function transfer({ nonce, amount, at, statuses, hash = "0x" + "ab".repeat(32), error = "synthetic error" }) {
  const reserve = { at, amount_usdt: amount, to: TO, purpose: PURPOSE, status: "reserved" };
  if (nonce !== undefined) reserve.nonce = nonce;
  return statuses.map((st, i) => {
    if (st === "reserved") return reserve;
    if (st === "broadcast_failed") return { ...reserve, status: st, error };
    if (st === "broadcast") return { ...reserve, status: st, tx_hash: hash };
    return { ...reserve, status: st, tx_hash: hash, block: 25918899 + i }; // confirmed | reverted
  });
}
const RBC = ["reserved", "broadcast", "confirmed"];

function buildCases(day) {
  const yday = new Date(Date.parse(day + "T00:00:00Z") - 86400e3).toISOString().slice(0, 10);
  const T = (hh, mm, ss = "00", ms = "000") => `${day}T${hh}:${mm}:${ss}.${ms}Z`;
  const Y = (hh, mm, ss = "00", ms = "000") => `${yday}T${hh}:${mm}:${ss}.${ms}Z`;
  const C = [];
  const add = (id, title, lines, expect, v021, note = "") => C.push({ id, title, lines, expect, v021, note });

  add("a", "5 transfers x 3 lines (reserved/broadcast/confirmed), distinct nonces -> each summed once",
    [[100, 0.50], [101, 0.30], [102, 1.00], [103, 0.20], [104, 0.70]].flatMap(([n, a], i) => transfer({ nonce: n, amount: a, at: T("10", String(10 + i).padStart(2, "0")), statuses: RBC })),
    2.70, 2.70, "v0.2 sum-every-line would read 8.10 (the #15457 incident class)");
  add("b", "reserved then broadcast_failed, same nonce -> 0 counted",
    transfer({ nonce: 105, amount: 1.00, at: T("11", "00"), statuses: ["reserved", "broadcast_failed"] }),
    0.00, 0.00);
  add("c", "reserved with no follow-up (in-flight) -> counted",
    transfer({ nonce: 106, amount: 0.40, at: T("11", "05"), statuses: ["reserved"] }),
    0.40, 0.40);
  add("d", "yesterday's confirmed transfer only -> ignored today",
    transfer({ nonce: 90, amount: 5.00, at: Y("10", "00"), statuses: RBC }),
    0.00, 0.00);
  add("d2", "reserve stamped 23:59:59.900Z yesterday, confirmed today -> all 3 lines carry the reserve's `at` -> yesterday's bucket",
    transfer({ nonce: 91, amount: 3.00, at: Y("23", "59", "59", "900"), statuses: RBC }),
    0.00, 0.00, "ledger buckets by reserve time; blockscout buckets by block time (today) -> Math.max covers it only while the indexer is reachable");
  add("e", "same nonce on different days (yesterday reserved+broadcast_failed, today reserved/broadcast/confirmed) -> today counted once",
    [...transfer({ nonce: 107, amount: 1.00, at: Y("12", "00"), statuses: ["reserved", "broadcast_failed"] }),
     ...transfer({ nonce: 107, amount: 0.50, at: T("12", "00"), statuses: RBC })],
    0.50, 0.50, "date filter runs before keying, so the key needs no date");
  add("e2", "nonce-less lines (fallback key = at) that share the reserve's `at`, as the signer writes them -> once",
    transfer({ amount: 0.60, at: T("12", "10"), statuses: RBC }),
    0.60, 0.60, "signer.mjs lines 92/96/99/104 all spread `reserve`: nonce AND at are identical on every line of a transfer");
  add("e3", "nonce-less lines with a DISTINCT `at` per line (a writer that re-stamps each line) -> fallback key splits the transfer",
    [{ at: T("12", "20"), amount_usdt: 0.60, to: TO, purpose: PURPOSE, status: "reserved" },
     { at: T("12", "20", "01"), amount_usdt: 0.60, to: TO, purpose: PURPOSE, status: "broadcast", tx_hash: "0x" + "cd".repeat(32) },
     { at: T("12", "20", "02"), amount_usdt: 0.60, to: TO, purpose: PURPOSE, status: "confirmed", tx_hash: "0x" + "cd".repeat(32), block: 1 }],
    0.60, 1.80, "latent: no such writer exists today (only signer.mjs appends to spend.ledger; pay.sh `ledger` reads); over-count = safe direction");
  add("f", "reserved then broadcast_failed with the IDENTICAL `at` string, file order R,F -> `>=` lets the later-read line win -> 0",
    transfer({ nonce: 108, amount: 1.00, at: T("13", "00"), statuses: ["reserved", "broadcast_failed"] }),
    0.00, 0.00, "all lines of a transfer share `at` by construction, so `>=` == file order; the writer appends chronologically under one process");
  add("f2", "same lines in REVERSED file order (F then R, same `at`) -> the later-read line (reserved) wins -> counted",
    transfer({ nonce: 108, amount: 1.00, at: T("13", "00"), statuses: ["broadcast_failed", "reserved"] }),
    1.00, 1.00, "file order is the only tiebreak; cannot happen with the single-process appender, shown for determinism");
  add("g", "float boundary: ten confirmed transfers 0.10..1.00 (nominal 5.50) -> is `spent + 4.50 > 10` false?",
    Array.from({ length: 10 }, (_, i) => transfer({ nonce: 120 + i, amount: (i + 1) / 10, at: T("13", String(10 + i).padStart(2, "0")), statuses: RBC })).flat(),
    5.50, 5.50, "cap compare is on binary floats (signer.mjs:65); see the float line below the table");
  add("h", "same-day nonce reuse: 1.00 broadcast (unconfirmed, exit 3, dropped by the RPC's mempool) then retry 0.50 with the same nonce -> latest line wins",
    [...transfer({ nonce: 130, amount: 1.00, at: T("14", "00"), statuses: ["reserved", "broadcast"], hash: "0x" + "11".repeat(32) }),
     ...transfer({ nonce: 130, amount: 0.50, at: T("14", "20"), statuses: RBC, hash: "0x" + "22".repeat(32) })],
    1.00, 0.50, "one nonce mines at most once but the ledger cannot know which hash; safe = max amount over the nonce's hashed lines. v0.2 counted 3.50");
  add("i", "reserved then broadcast_failed whose error is a transport timeout (node may have accepted the tx) -> released to 0",
    transfer({ nonce: 131, amount: 1.00, at: T("15", "00"), statuses: ["reserved", "broadcast_failed"], error: "request timeout" }),
    1.00, 0.00, "signer.mjs:96 releases on ANY throw from usdt.transfer; a timeout after eth_sendRawTransaction reached the node still mines. v0.2 counted 2.00");
  add("j", "two writers, same nonce (signerd spawns signer.mjs without pay.sh's flock): A reserved 2.00 + broadcast; B reserved 0.30 + broadcast_failed (underpriced); A exits 3 (no confirmed line)",
    [transfer({ nonce: 132, amount: 2.00, at: T("16", "00"), statuses: ["reserved"] })[0],
     transfer({ nonce: 132, amount: 0.30, at: T("16", "00", "00", "050"), statuses: ["reserved"] })[0],
     transfer({ nonce: 132, amount: 2.00, at: T("16", "00"), statuses: ["reserved", "broadcast"], hash: "0x" + "33".repeat(32) })[1],
     transfer({ nonce: 132, amount: 0.30, at: T("16", "00", "00", "050"), statuses: ["reserved", "broadcast_failed"], error: "replacement transaction underpriced" })[1]],
    2.00, 0.00, "B's later `at` wins the nonce and its status is broadcast_failed -> A's live 2.00 broadcast is released. v0.2 counted 4.60");
  add("k", "one valid transfer 1.00 + one truncated JSON line + one line without `at` (2.00) -> the two bad lines vanish silently",
    { raw: [...transfer({ nonce: 133, amount: 1.00, at: T("17", "00"), statuses: RBC }).map(o => JSON.stringify(o)),
            '{"at":"' + T("17", "01") + '","amount_usdt":2.00,"nonce":134,"status":"reser',
            JSON.stringify({ amount_usdt: 2.00, nonce: 135, to: TO, purpose: PURPOSE, status: "reserved" })] },
    "REFUSE", 1.00, "ledgerLines() (signer.mjs:40) drops unparseable lines, the date filter drops lines without `at`: fail-open on a corrupt ledger");
  add("l", "reserved/broadcast/reverted (ERC-20 revert, no USDT moved) -> still counted",
    transfer({ nonce: 136, amount: 1.00, at: T("18", "00"), statuses: ["reserved", "broadcast", "reverted"] }),
    1.00, 1.00, "only broadcast_failed is excluded; a revert charges the day (false-refusal class, safe direction)");
  add("m", "nonce 0 (first transfer of an account): `??` keeps \"0\" as the key (|| would have fallen back to at)",
    transfer({ nonce: 0, amount: 0.25, at: T("18", "30"), statuses: RBC }),
    0.25, 0.25);
  return C;
}

function runCases(dir) {
  const day0 = utcDay();
  const cases = buildCases(day0);
  fs.mkdirSync(dir, { recursive: true });
  const rows = []; let fails = 0, gaps = 0, passes = 0;
  for (const c of cases) {
    const file = path.join(dir, `ledger-${c.id}.jsonl`);
    const text = Array.isArray(c.lines) ? c.lines.map(o => JSON.stringify(o)).join("\n") + "\n" : c.lines.raw.join("\n") + "\n";
    fs.writeFileSync(file, text, { mode: 0o600 });
    const actual = r2(evalLedgerToday(file)); const ins = inspect(file);
    let verdict;
    if (c.expect === "REFUSE") verdict = (ins.lines_unparseable + ins.lines_today_without_at) > 0 ? (actual === c.v021 ? "GAP" : "FAIL") : "FAIL";
    else if (actual === c.expect) verdict = "PASS";
    else if (actual === c.v021) verdict = "GAP";
    else verdict = "FAIL";
    if (verdict === "PASS") passes++; else if (verdict === "GAP") gaps++; else fails++;
    rows.push({ id: c.id, verdict, actual, expect: c.expect, v021: c.v021, v02_sum_all: ins.v0_2_sum_all_today, lines: ins.lines_raw, keys: ins.keys_today.length, title: c.title, note: c.note, file });
  }
  console.log(`signer-ledger-test.mjs --cases  today=${day0}  fixtures=${dir}`);
  console.log("case  verdict  actual  safe    v0.2.1  v0.2(sum-all)  lines keys  title");
  for (const r of rows) console.log(`${r.id.padEnd(5)} ${r.verdict.padEnd(8)} ${String(r.actual.toFixed(2)).padEnd(7)} ${String(r.expect === "REFUSE" ? "REFUSE" : r.expect.toFixed(2)).padEnd(7)} ${String(r.v021.toFixed(2)).padEnd(7)} ${String(r.v02_sum_all.toFixed(2)).padEnd(14)} ${String(r.lines).padEnd(5)} ${String(r.keys).padEnd(5)} ${r.title}`);
  console.log("notes:"); for (const r of rows) if (r.note) console.log(`  ${r.id}: ${r.note}`);
  // (g) float boundary, as the signer compares it (signer.mjs:65): spentToday + amountNum > MAX_PER_DAY
  const g = rows.find(r => r.id === "g"); const gRaw = evalLedgerToday(g.file); const rest = 10 - 5.5;
  console.log(`float: case g raw sum = ${gRaw} ; ${gRaw} + ${rest} > 10 -> ${gRaw + rest > 10} (a send of exactly the remaining cap is ${gRaw + rest > 10 ? "REFUSED: false refusal at the boundary" : "allowed"})`);
  // mutation checks: does the harness have teeth, and which token of the expression is load-bearing?
  const muts = [
    ["M1 `>=` -> `>` (first-read line wins)", [[">= String(prev.at)", "> String(prev.at)"]]],
    ["M2 key `l.nonce ?? l.at` -> `l.at` (nonce ignored)", [["String(l.nonce ?? l.at)", "String(l.at)"]]],
    ["M3 drop the broadcast_failed exclusion", [['if (l.status !== "broadcast_failed") s +=', "s +="]]],
  ];
  console.log("mutations (actual under the mutated expression; * marks a change vs v0.2.1):");
  for (const [name, reps] of muts) {
    const fn = mutant(reps);
    const out = rows.map(r => { const v = r2(fn(fs, r.file)); return `${r.id}=${v.toFixed(2)}${v !== r.actual ? "*" : ""}`; }).join(" ");
    console.log(`  ${name}: ${out}`);
  }
  const day1 = utcDay(); if (day1 !== day0) console.log(`WARNING: UTC day changed during the run (${day0} -> ${day1}); rerun`);
  console.log(`summary: PASS ${passes}  GAP ${gaps}  FAIL ${fails}  (exit ${fails ? 1 : 0}; GAP = finding against v0.2.1, not a harness failure)`);
  process.exit(fails ? 1 : 0);
}

function verifyVerbatim(signerPath) {
  const src = fs.readFileSync(signerPath, "utf8"); const lines = src.split("\n");
  console.log(`signer: ${signerPath} sha256 ${createHash("sha256").update(src).digest("hex")} (${src.length} chars)`);
  let ok = true;
  for (const l of verbatimBlock()) {
    const idx = lines.indexOf(l);
    console.log(`${idx >= 0 ? "OK  " : "MISS"} signer line ${idx >= 0 ? idx + 1 : "-"}: ${l.slice(0, 60)}...`);
    if (idx < 0) ok = false;
  }
  console.log(ok ? "VERBATIM: all copied lines are byte-identical in the signer" : "DRIFT: the signer no longer contains the copied line(s); update the harness");
  process.exit(ok ? 0 : 1);
}
const [arg, arg2] = process.argv.slice(2);
if (arg === "--cases") runCases(arg2 || fs.mkdtempSync(path.join(os.tmpdir(), "signer-ledger-test-")));
else if (arg === "--verify-verbatim") { if (!arg2) { console.error("usage: --verify-verbatim <signer.mjs>"); process.exit(2); } verifyVerbatim(arg2); }
else if (arg && !arg.startsWith("-")) { const v = evalLedgerToday(arg); console.log(JSON.stringify({ ledger: arg, today: utcDay(), ledger_today: v, ...inspect(arg) }, null, 1)); }
else { console.error("usage: signer-ledger-test.mjs <ledger.jsonl> | --cases [dir] | --verify-verbatim <signer.mjs>"); process.exit(2); }
