// signer.mjs v0.2.2 — Abel's outbound USDT signer. Private key is read INSIDE this process
// and never printed. Principal grant: ABEL.md v3 (2026-09-06). v0.2 closes abel-cain's
// signer red-team (dispatch 3, 2026-09-06T07:55Z): fixed paths (no env overrides), append-only
// spend ledger + on-chain cross-check for the daily cap, payee guard (zero/burn/contract),
// purpose sanitization, broadcast receipt BEFORE waiting, pending-nonce check, hard fee ceiling.
// Honest limit (finding 8): every persona runs as the same Unix user; caps here are policy the
// same account could edit. Real enforcement needs a separate OS account owning key + signer.
//   node signer.mjs quote <to> <amount_usdt> "<purpose>"    -> JSON, nothing sent
//   node signer.mjs send  <to> <amount_usdt> "<purpose>"    -> ledger reserve, broadcast, receipt, wait
// exit 0 confirmed | 3 broadcast but unconfirmed within the wait | 1 refused or failed before broadcast
import { ethers } from "ethers";
import fs from "node:fs";
const [mode, toArg, amountArg, purposeArg] = process.argv.slice(2);
const KEYFILE = "/home/ye/PROJECTS/agent-space/wallet/PRIVATE_KEY.txt";
const LEDGER = "/home/ye/.agent-link/signer/spend.ledger";           // append-only, one JSON line per broadcast
const RECEIPTS = "/home/ye/PROJECTS/agent-space/agent-link/receipts"; // fixed, not overridable
const TREASURY = "0x9b349A3bc383c2CD752aF69e856e671F8E10a030";
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const MAX_PER_TX = 5.0, MAX_PER_DAY = 10.0, MIN_PURPOSE = 20;
const MAX_FEE_GWEI = 3.0, MAX_PRIORITY_GWEI = 1.0, WAIT_MS = 180000;
const BURN = new Set(["0x0000000000000000000000000000000000000000", "0x000000000000000000000000000000000000dead", "0x00000000000000000000000000000000deadbeef", "0x000000000000000000000000000000000000dEaD".toLowerCase()]);
const RPCS = ["https://ethereum-rpc.publicnode.com", "https://cloudflare-eth.com", "https://1rpc.io/eth"];
const out = (o) => process.stdout.write(JSON.stringify(o, null, 1) + "\n");
const fail = (why, extra = {}) => { out({ ok: false, mode, error: why, ...extra }); process.exit(1); };
const today = () => new Date().toISOString().slice(0, 10);
if (!["quote", "send"].includes(mode)) fail("usage: signer.mjs quote|send <to> <amount_usdt> <purpose>");
// ---- inputs ----
let to; try { to = ethers.getAddress(toArg || ""); } catch { fail("bad recipient address"); }
if (to.toLowerCase() === TREASURY.toLowerCase()) fail("recipient is the treasury itself");
if (BURN.has(to.toLowerCase())) fail("recipient is a burn/zero address — not a payee");
const purpose = String(purposeArg ?? "");
if (/[\r\n\t]/.test(purpose)) fail("policy: purpose must be a single line (no newline/tab)");
if (purpose.length < MIN_PURPOSE || purpose.length > 400) fail(`policy: purpose must be ${MIN_PURPOSE}..400 chars and cite a board seq or receipt`);
if (!/(seq\s*\d+|#\d+|receipts?\/|receipt)/i.test(purpose)) fail("policy: purpose must reference a board seq or a receipt path");
if (!/^\d+(\.\d{1,6})?$/.test(amountArg || "")) fail("bad amount (USDT, max 6 decimals)");
const amountNum = Number(amountArg);
if (!(amountNum > 0)) fail("amount must be > 0");
if (amountNum > MAX_PER_TX) fail(`policy: ${amountNum} USDT exceeds per-transfer cap ${MAX_PER_TX} (refused, not escalated)`);
// ---- spend ledger (append-only) ----
function ledgerLines() { let raw; try { raw = fs.readFileSync(LEDGER, "utf8"); } catch { return []; } const out = []; for (const l of raw.split("\n").filter(Boolean)) { try { out.push(JSON.parse(l)); } catch { fail("ledger line unparsable: refusing (fail closed) — repair the ledger by hand", { line: l.slice(0, 80) }); } } return out; } // v0.2.2 (cain #15612): corrupt line = fail closed, never undercount
// v0.2.2 (cain #15612): count each transfer ATTEMPT once — key = nonce + the reservation timestamp that every
// line of an attempt carries — and count every attempt regardless of status, including broadcast_failed: a
// broadcast that threw after reaching the network can still mine, so a "failed" line must not release the
// amount (conservative; the daily cap may over-count by a failed attempt, never under-count).
const ledgerToday = (() => { const byAttempt = new Map(); for (const l of ledgerLines()) { if ((l.at || "").slice(0, 10) !== today()) continue; const k = String(l.nonce ?? "") + "|" + String(l.at); if (!byAttempt.has(k)) byAttempt.set(k, l); } let s = 0; for (const l of byAttempt.values()) s += Number(l.amount_usdt || 0); return s; })();
// ---- provider(s) ----
const providers = [];
for (const u of RPCS) { try { const p = new ethers.JsonRpcProvider(u, 1, { staticNetwork: true }); await p.getBlockNumber(); providers.push(p); } catch {} }
if (!providers.length) fail("no RPC reachable");
const provider = providers[0];
// ---- on-chain cross-check of today's outbound USDT (Blockscout indexer, read-only) ----
let chainToday = 0, chainSrc = "unavailable";
try {
  const r = await fetch(`https://eth.blockscout.com/api/v2/addresses/${TREASURY}/token-transfers?type=ERC-20&filter=from`, { signal: AbortSignal.timeout(20000) });
  const j = await r.json();
  for (const t of (j.items || [])) {
    const tok = t.token || {}; const taddr = (tok.address || tok.address_hash || "").toLowerCase();
    if (taddr !== USDT.toLowerCase() && tok.symbol !== "USDT") continue;
    if ((t.from?.hash || "").toLowerCase() !== TREASURY.toLowerCase()) continue;
    if ((t.timestamp || "").slice(0, 10) !== today()) continue;
    chainToday += Number(t.total?.value || 0) / 10 ** Number(t.total?.decimals || 6);
  }
  chainSrc = "eth.blockscout.com";
} catch {}
const spentToday = Math.max(ledgerToday, chainToday);
if (spentToday + amountNum > MAX_PER_DAY) fail(`policy: daily cap ${MAX_PER_DAY} USDT would be exceeded`, { ledger_today: ledgerToday, chain_today: chainToday, chain_source: chainSrc });
// ---- payee must be an externally owned account (or explicitly a known contract) ----
const code = await provider.getCode(to);
if (code !== "0x") fail("recipient is a contract; refusing (ERC-20 sent to a contract may be unrecoverable)", { code_bytes: (code.length - 2) / 2 });
// ---- key: read, use, never echo ----
let key; try { key = fs.readFileSync(KEYFILE, "utf8").trim(); } catch { fail("key file unreadable (sealed)"); }
if (!key.startsWith("0x")) key = "0x" + key;
let wallet; try { wallet = new ethers.Wallet(key, provider); } catch { fail("key file content is not a private key"); }
key = null;
if (wallet.address.toLowerCase() !== TREASURY.toLowerCase()) fail("key does not control the treasury address — refusing");
const usdt = new ethers.Contract(USDT, ["function transfer(address to, uint256 value)", "function balanceOf(address) view returns (uint256)"], wallet);
const amount = ethers.parseUnits(amountArg, 6);
const [usdtBal, ethBal, fee, nonceLatest, noncePending] = await Promise.all([usdt.balanceOf(TREASURY), provider.getBalance(TREASURY), provider.getFeeData(), provider.getTransactionCount(TREASURY, "latest"), provider.getTransactionCount(TREASURY, "pending")]);
if (noncePending !== nonceLatest) fail("a previous transaction is still pending; refusing to stack sends", { nonce_latest: nonceLatest, nonce_pending: noncePending });
if (usdtBal < amount) fail("insufficient USDT", { usdt_balance: ethers.formatUnits(usdtBal, 6) });
let gasLimit; try { gasLimit = await usdt.transfer.estimateGas(to, amount); } catch (e) { fail("gas estimate failed (blacklist/revert?): " + (e.shortMessage || e.message)); }
gasLimit = gasLimit * 120n / 100n;
const feeCap = ethers.parseUnits(String(MAX_FEE_GWEI), "gwei"), prioCap = ethers.parseUnits(String(MAX_PRIORITY_GWEI), "gwei");
let maxFeePerGas = fee.maxFeePerGas ?? fee.gasPrice ?? 0n, maxPriorityFeePerGas = fee.maxPriorityFeePerGas ?? 0n;
if (maxFeePerGas > feeCap) fail("gas price above the hard ceiling; try later", { rpc_max_fee_gwei: Number(maxFeePerGas) / 1e9, ceiling_gwei: MAX_FEE_GWEI });
if (maxPriorityFeePerGas > prioCap) maxPriorityFeePerGas = prioCap;
const estFee = gasLimit * maxFeePerGas;
if (ethBal < estFee * 3n) fail("ETH for gas below 3x the estimated fee", { eth_balance: ethers.formatEther(ethBal), est_fee_eth: ethers.formatEther(estFee) });
const summary = { ok: true, mode, from: TREASURY, to, amount_usdt: amountNum, purpose, nonce: nonceLatest, gas_limit: Number(gasLimit), max_fee_gwei: Number(maxFeePerGas) / 1e9, fee_ceiling_gwei: MAX_FEE_GWEI, est_fee_eth: ethers.formatEther(estFee), eth_balance: ethers.formatEther(ethBal), usdt_balance: ethers.formatUnits(usdtBal, 6), spent_today_usdt: spentToday, ledger_today: ledgerToday, chain_today: chainToday, chain_source: chainSrc, caps: { per_tx: MAX_PER_TX, per_day: MAX_PER_DAY }, chain_id: 1, token: USDT, at: new Date().toISOString() };
if (mode === "quote") { out({ ...summary, sent: false }); process.exit(0); }
if (process.env.ABEL_PAYOUT_OK !== "1") fail("send refused: ABEL_PAYOUT_OK=1 not set (deliberate flag)", summary);
// ---- reserve in the ledger BEFORE broadcasting (append-only; the caller holds the flock) ----
const reserve = { at: new Date().toISOString(), amount_usdt: amountNum, to, nonce: nonceLatest, purpose, status: "reserved" };
fs.appendFileSync(LEDGER, JSON.stringify(reserve) + "\n", { mode: 0o600 });
let tx;
try { tx = await usdt.transfer(to, amount, { gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce: nonceLatest }); }
catch (e) { fs.appendFileSync(LEDGER, JSON.stringify({ ...reserve, status: "broadcast_failed", error: String(e.shortMessage || e.message) }) + "\n"); fail("broadcast failed: " + (e.shortMessage || e.message), summary); }
// broadcast receipt FIRST (finding 4): the hash exists before we wait for anything
const bcast = { ...summary, sent: true, confirmed: false, tx_hash: tx.hash, broadcast_at: new Date().toISOString() };
fs.appendFileSync(LEDGER, JSON.stringify({ ...reserve, status: "broadcast", tx_hash: tx.hash }) + "\n");
try { fs.writeFileSync(`${RECEIPTS}/${bcast.broadcast_at.replace(/[:.]/g, "").slice(0, 15)}Z-payout-broadcast-${tx.hash.slice(2, 10)}.json`, JSON.stringify(bcast, null, 1) + "\n", { mode: 0o600 }); } catch {}
let rec = null;
try { rec = await tx.wait(1, WAIT_MS); } catch {}
if (!rec) { out({ ...bcast, note: "unconfirmed within wait window; check the hash before any retry — NEVER re-send blindly" }); process.exit(3); }
fs.appendFileSync(LEDGER, JSON.stringify({ ...reserve, status: rec.status === 1 ? "confirmed" : "reverted", tx_hash: tx.hash, block: rec.blockNumber }) + "\n");
out({ ...bcast, confirmed: rec.status === 1, block: rec.blockNumber, status: rec.status, gas_used: Number(rec.gasUsed), fee_eth: ethers.formatEther(rec.gasUsed * (rec.gasPrice ?? maxFeePerGas)), confirmed_at: new Date().toISOString() });
process.exit(rec.status === 1 ? 0 : 1);
