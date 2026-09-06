#!/usr/bin/env node
// swap_quote.mjs v0.1 — READ-ONLY quote from Uniswap v3 QuoterV2 on Ethereum mainnet via eth_call.
// No key, no approval, no swap: this is the "quote → slippage bound" half of the swap module, shipped
// first so the math is checkable against the deployed contract before any transaction exists.
//   node swap_quote.mjs <amount_in_usdt> [slippage_bps=50] [rpc]
// Pool: USDT -> WETH, fee tier 0.05% (500). Prints amountOut, the minimum-out bound at the given
// slippage, gas estimate from the quoter, and the exact calldata used, so a stranger can replay it.
import { ethers } from "ethers";
const [amountArg = "1", bpsArg = "50", rpcArg = "https://eth.drpc.org"] = process.argv.slice(2);
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7", WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const QUOTER_V2 = "0x61fFE014bA17989E743c5F6cB21bF9697530B21e";
const iface = new ethers.Interface(["function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96)) returns (uint256 amountOut,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)"]);
const amountIn = ethers.parseUnits(String(amountArg), 6); const bps = BigInt(bpsArg);
const data = iface.encodeFunctionData("quoteExactInputSingle", [{ tokenIn: USDT, tokenOut: WETH, amountIn, fee: 500, sqrtPriceLimitX96: 0 }]);
const RPCS = [rpcArg, "https://ethereum-rpc.publicnode.com", "https://1rpc.io/eth", "https://eth.drpc.org"].filter((v, i, a) => a.indexOf(v) === i);
let res = null, used = null, errs = [];
for (const url of RPCS) {
  try { const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: QUOTER_V2, data }, "latest"] }), signal: AbortSignal.timeout(15000) }).then((r) => r.json()); if (r && r.result) { res = r; used = url; break; } errs.push({ url, error: r && r.error }); } catch (e) { errs.push({ url, error: String(e.message || e) }); }
}
if (!res) { console.log(JSON.stringify({ ok: false, error: "all RPCs failed", tried: errs, calldata: data })); process.exit(1); }
const rpcArgUsed = used;
const [amountOut, , ticks, gas] = iface.decodeFunctionResult("quoteExactInputSingle", res.result);
const minOut = amountOut - (amountOut * bps) / 10000n;
console.log(JSON.stringify({ ok: true, pool: "USDT/WETH 0.05%", quoter: QUOTER_V2, amount_in_usdt: Number(amountArg), amount_out_weth: ethers.formatEther(amountOut), min_out_weth_at_slippage: ethers.formatEther(minOut), slippage_bps: Number(bps), ticks_crossed: Number(ticks), quoter_gas_estimate: Number(gas), calldata: data, rpc: rpcArgUsed, at: new Date().toISOString(), note: "quote only; nothing approved or sent; allowance policy = exact amountIn per swap (THREAT-MODEL C8)" }, null, 1));
