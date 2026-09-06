// signer.mjs — Abel's outbound USDT signer. The private key is read INSIDE this
// process and is never printed, logged, or returned. Principal grant recorded in
// ABEL.md (2026-09-06). Policy caps live here on purpose: changing them is a code
// change with a diff, not a prompt.
//   node signer.mjs quote <to> <amount_usdt> "<purpose>"   -> JSON, no send
//   node signer.mjs send  <to> <amount_usdt> "<purpose>"   -> broadcasts, waits 1 conf (needs ABEL_PAYOUT_OK=1)
import { ethers } from "ethers";
import fs from "node:fs";
const [mode, toArg, amountArg, purpose] = process.argv.slice(2);
const KEYFILE = process.env.ABEL_KEYFILE || "/home/ye/PROJECTS/agent-space/wallet/PRIVATE_KEY.txt";
const TREASURY = "0x9b349A3bc383c2CD752aF69e856e671F8E10a030";
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const MAX_PER_TX = 5.0, MAX_PER_DAY = 10.0, MIN_PURPOSE = 20;
const RECEIPTS = process.env.ABEL_RECEIPTS || "/home/ye/PROJECTS/agent-space/agent-link/receipts";
const RPCS = ["https://ethereum-rpc.publicnode.com", "https://cloudflare-eth.com", "https://1rpc.io/eth"];
const out = (o) => { process.stdout.write(JSON.stringify(o, null, 1) + "\n"); };
const fail = (why, extra = {}) => { out({ ok: false, mode, error: why, ...extra }); process.exit(1); };
if (!["quote", "send"].includes(mode)) fail("usage: signer.mjs quote|send <to> <amount_usdt> <purpose>");
let to; try { to = ethers.getAddress(toArg || ""); } catch { fail("bad recipient address"); }
if (to.toLowerCase() === TREASURY.toLowerCase()) fail("recipient is the treasury itself");
const amountNum = Number(amountArg);
if (!(amountNum > 0) || !/^\d+(\.\d{1,6})?$/.test(amountArg || "")) fail("bad amount (USDT, max 6 decimals)");
if (amountNum > MAX_PER_TX) fail(`policy: ${amountNum} USDT exceeds per-transfer cap ${MAX_PER_TX}`);
if (!purpose || purpose.length < MIN_PURPOSE) fail(`policy: purpose must be >= ${MIN_PURPOSE} chars and cite a board seq or receipt`);
if (!/(seq\s*\d+|#\d+|receipts?\/|receipt)/i.test(purpose)) fail("policy: purpose must reference a board seq or a receipt path");
// daily cap from payout receipts written today (UTC)
const today = new Date().toISOString().slice(0, 10);
let spentToday = 0;
try { for (const f of fs.readdirSync(RECEIPTS)) if (f.startsWith(today) && f.includes("-payout-")) { try { const r = JSON.parse(fs.readFileSync(`${RECEIPTS}/${f}`, "utf8")); if (r.sent) spentToday += Number(r.amount_usdt || 0); } catch {} } } catch {}
if (spentToday + amountNum > MAX_PER_DAY) fail(`policy: daily cap ${MAX_PER_DAY} USDT would be exceeded (spent today ${spentToday})`);
// provider
let provider = null;
for (const u of RPCS) { try { const p = new ethers.JsonRpcProvider(u, 1, { staticNetwork: true }); await p.getBlockNumber(); provider = p; break; } catch {} }
if (!provider) fail("no RPC reachable");
// key: read, use, never echo
let key; try { key = fs.readFileSync(KEYFILE, "utf8").trim(); } catch { fail("key file unreadable (sealed)"); }
if (!key.startsWith("0x")) key = "0x" + key;
let wallet; try { wallet = new ethers.Wallet(key, provider); } catch { fail("key file content is not a private key"); }
key = null;
if (wallet.address.toLowerCase() !== TREASURY.toLowerCase()) fail("key does not control the treasury address — refusing");
const usdt = new ethers.Contract(USDT, ["function transfer(address to, uint256 value)", "function balanceOf(address) view returns (uint256)"], wallet);
const amount = ethers.parseUnits(amountArg, 6);
const [usdtBal, ethBal, fee, nonce] = await Promise.all([usdt.balanceOf(TREASURY), provider.getBalance(TREASURY), provider.getFeeData(), provider.getTransactionCount(TREASURY, "latest")]);
if (usdtBal < amount) fail("insufficient USDT", { usdt_balance: ethers.formatUnits(usdtBal, 6) });
let gasLimit; try { gasLimit = await usdt.transfer.estimateGas(to, amount); } catch (e) { fail("gas estimate failed: " + (e.shortMessage || e.message)); }
gasLimit = gasLimit * 120n / 100n;
const maxFeePerGas = fee.maxFeePerGas ?? fee.gasPrice, maxPriorityFeePerGas = fee.maxPriorityFeePerGas ?? 0n;
const estFee = gasLimit * maxFeePerGas;
if (ethBal < estFee * 3n) fail("ETH for gas below 3x the estimated fee", { eth_balance: ethers.formatEther(ethBal), est_fee_eth: ethers.formatEther(estFee) });
const summary = { ok: true, mode, from: TREASURY, to, amount_usdt: amountNum, purpose, nonce, gas_limit: Number(gasLimit), max_fee_gwei: Number(maxFeePerGas) / 1e9, est_fee_eth: ethers.formatEther(estFee), eth_balance: ethers.formatEther(ethBal), usdt_balance: ethers.formatUnits(usdtBal, 6), spent_today_usdt: spentToday, caps: { per_tx: MAX_PER_TX, per_day: MAX_PER_DAY }, chain_id: 1, token: USDT, at: new Date().toISOString() };
if (mode === "quote") { out({ ...summary, sent: false }); process.exit(0); }
if (process.env.ABEL_PAYOUT_OK !== "1") fail("send refused: ABEL_PAYOUT_OK=1 not set (deliberate flag)", summary);
const tx = await usdt.transfer(to, amount, { gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce });
const rec = await tx.wait(1);
out({ ...summary, sent: true, tx_hash: tx.hash, block: rec.blockNumber, status: rec.status, gas_used: Number(rec.gasUsed), fee_eth: ethers.formatEther(rec.gasUsed * (rec.gasPrice ?? maxFeePerGas)), confirmed_at: new Date().toISOString() });
