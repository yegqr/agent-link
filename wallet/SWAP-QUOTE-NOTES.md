# AgentWallet: swap quote integration notes

W-2 by Pilot Finch, 2026-09-06. License: MIT.
Scope: `wallet/swap_quote.mjs` at `aecd5a2c31d9c248041bc495d93ffa922f1b432f`, SHA-256 `d5a02839a64cbf45001f7c8aa8c1b7de05fc53300a25e7a2757e7aab95879513`.
This is interface documentation and an offline arithmetic example. No fresh market quote, wallet operation or security audit was performed.

## Contract and ABI

Ethereum mainnet (chain ID 1) QuoterV2: `0x61fFE014bA17989E743c5F6cB21bF9697530B21e`. The official [Ethereum deployment table](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-ethereum-deployments) lists it. Do not substitute the older Quoter ABI.

The canonical function signature is `quoteExactInputSingle((address,address,uint256,uint24,uint160))`. Its selector is `0xc6a5026a`: the first four bytes of Ethereum Keccak-256 of that ASCII signature (not NIST SHA3-256). The [official IQuoterV2 interface](https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/IQuoterV2.sol) defines this field order:

| Input field | Type | This example |
|---|---|---|
| tokenIn | address | USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| tokenOut | address | WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| amountIn | uint256 | 1,000,000 raw USDT units |
| fee | uint24 | 500, i.e. 0.05% pool fee |
| sqrtPriceLimitX96 | uint160 | 0, the quoter's default-limit sentinel |

Return order is `(uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)`. `amountOut` is in output-token base units. `sqrtPriceX96After` is the simulated post-swap square-root pool price in Q64.96, using the pool's token0/token1 convention; it is not a human USDT/WETH exchange-rate decimal. `initializedTicksCrossed` counts initialized ticks crossed during the simulation; `gasEstimate` estimates the quoted path's execution work.

All tuple fields are static. After the 4-byte selector, encode five 32-byte words directly, without a dynamic-tuple offset. Addresses are left-padded with 12 zero bytes; integers are unsigned and big-endian. For 1 USDT, fee 500, the words are:

```text
c6a5026a
000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7
000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
00000000000000000000000000000000000000000000000000000000000f4240
00000000000000000000000000000000000000000000000000000000000001f4
0000000000000000000000000000000000000000000000000000000000000000
```

Concatenate these lines and prepend `0x`: 164 bytes total. Reading the five words back yields exactly the table above. These bytes are reconstructed from the pinned source's arguments; they are not presented as a captured historical RPC response. The client can compare its printed `calldata` directly with this deterministic string. `fee` follows `amountIn` in this tuple.

## Units and integer arithmetic

This integration uses USDT with 6 decimals and WETH with 18. Thus `1 USDT = 1 * 10^6 = 1000000` raw input units. Convert WETH raw output to decimal text by inserting a decimal point 18 digits from the right; avoid floating-point arithmetic for accounting.

The buyer-supplied historical example is:

```text
amountOut = 401413098299402 wei = 0.000401413098299402 WETH
slippageBps = 50; denominator = 10000; 50 bps = 0.50%
amountOut * 50 = 20070654914970100
deduction = floor(20070654914970100 / 10000) = 2007065491497
minOut = 401413098299402 - 2007065491497 = 399406032807905 wei
minOut decimal = 0.000399406032807905 WETH
```

This reproduces the pinned program's `A - (A * bps) / 10000n`, with nonnegative integer division. It equals `ceil(A * 9950 / 10000)`. Multiplying by 9950 and flooring instead produces `399406032807904`, one wei lower. This is a rounding distinction, not a new market-price observation. The 500 pool fee and 50 slippage bps use different denominators and are different quantities.

## Quote versus executed swap

QuoterV2 is intended to be simulated with `eth_call`. Its Solidity interface is not `view`, because its implementation simulates pool execution and uses reverts internally; this does not mean a caller must submit a transaction. A successful call describes the pool state used by that simulation. It neither reserves liquidity nor transfers USDT/WETH. It does not establish the caller's balance, allowance, future execution price, transaction inclusion, or success.

Ticks crossed and gas estimates are observations of that simulated path. They may change with pool state, and the estimate is not a complete future transaction fee including all router, token and approval overhead. Persist the chain ID, block reference, input, fee and timestamp alongside any real quote so its context is explicit.

For a future separately authorized swap, the project's exact-amount allowance policy grants the intended router only the input amount needed for that swap instead of an unlimited residual allowance. The Quoter itself needs no token allowance for this quote. Token-specific allowance updates belong to transaction execution, not this document's offline check.

Ordinary execution failures include an output below the router's minimum (slippage revert), an expired deadline, stale or unavailable pool state, and a token transfer failure. In the [official TransferHelper](https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/TransferHelper.sol), `STF` denotes a failed `transferFrom`; insufficient balance/allowance or token-specific restrictions are possible causes, not a diagnosis proven by the three letters alone. A historical quote does not prevent these failures.

## Checks before using a deployment

A reader should verify the intended network with `eth_chainId`; obtain nonempty `eth_getCode` at the Quoter, token, router and relevant pool addresses; compare deployment metadata and verified source/ABI with official references; confirm token decimals and the pool's tokens/fee through the intended chain's contracts; and record the block used. Nonempty code alone does not prove identity or correctness. Address spelling alone does not establish a deployment on another chain.

Those are checks for the future integrator. This delivery only checked the documented interface, deterministic calldata layout and the supplied arithmetic offline. It made no chain call, approval, signature or transfer.
