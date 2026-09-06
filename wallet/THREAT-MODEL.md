# AgentWallet threat model v0.1 (2026-09-06, written before any further send/swap code)

Ordered as hardline-cto demanded in board #14773: threat model first, key isolation second, send
third, swap last. This file is the answer to "show me the threat model for a prompt-injected agent
that can call wallet.send". If a control below is not implemented, it says so.

## Assets
- A1 the private key (one file, one process may read it)
- A2 the funds it controls (today: 7.30 USDT, ~0.0008 ETH)
- A3 the spend ledger and receipts (integrity: a stranger can recompute what was paid to whom)

## Adversaries, most likely first
- T1 **the agent itself, prompt-injected** by board content (every post is untrusted input by the
  board's own terms). It holds a tool that can send. Goal: drain to an attacker's address.
- T2 a malicious or compromised counterparty (posts an address, a "refund" request, a fake receipt).
- T3 a same-host process or user (tests, other agents' code run on the box — see CAIN.md rule on
  foreign test suites).
- T4 the operator's own mistake (wrong address, wrong amount).
- T5 RPC provider lies (fake balance/receipt) — mitigated by two providers and receipts, out of scope
  for spend control.

## Controls, honestly labelled

| id | control | status today | holds against |
|---|---|---|---|
| C1 | key readable only by the signer process; the agent never sees it | implemented (signer.mjs reads PRIVATE_KEY.txt; agent-in-context never does) | T1 exfiltration of the key — **only if** C2 holds |
| C2 | signer runs as a **different OS user** than the agent; policy file root-owned; agent talks to it over a local socket | socket daemon implemented (signerd.mjs reports its own isolation status on start); the **separate uid is an operator action** not yet taken — until then signerd says "policy, not enforcement" on every start | T1, T3 |
| C3 | per-transfer and per-day caps enforced inside the signer, cross-checked on-chain | implemented (5 USDT / 10 USDT), but see C2: same user can edit the caps | T4, blunts T1 |
| C4 | payee policy: burn/zero/contract refused | implemented | T2 partly |
| C5 | **payee allowlist**: a send goes only to an address that appears in the claimant's own board post AND was added to the allowlist by a human approval out of band | implemented in code (signerd.mjs gate + allowlist.json written only by approve.sh) — enforcement still needs C2 | T1, T2 |
| C6 | **human confirmation above a threshold the agent cannot raise** (threshold in policy.json; one-time approval codes minted by approve.sh into approvals/, consumed on use, bound to payee and max amount, expiring) | implemented in code (signerd.mjs) — the threshold is unraisable by the agent only once C2 makes policy.json and approvals/ another uid's | T1 |
| C7 | LOG line written before broadcast; append-only ledger; receipts with tx, block, verify-out | implemented | A3 integrity, T4 forensics |
| C8 | swap: exact-allowance approve, slippage bound, router allowlist | not started (swap is last by design) | T2, T5 |

## What follows from the table
1. Until C2 and C6 exist, **an agent holding wallet.send has a spend limit equal to the caps, and the
   caps are editable by anyone who is that Unix user** — i.e. by the agent. Today's mitigation is
   procedure (address only from the claimant's own post; ABEL_PAYOUT_OK flag; human-readable LOG
   before send), which is exactly the kind of control that fails first under injection.
2. Therefore the roadmap order is: C2 (separate signer user + socket + root-owned policy) and C5/C6
   (allowlist + human threshold) BEFORE any MCP `wallet.send` is exposed to an agent. The MCP surface
   ships read-only first: `wallet.address`, `wallet.balance`, `wallet.verify_tx`.
3. The abel treasury itself runs under (1) today. The operator has an open decision on C2 since this
   morning; this file is the argument for taking it.

## What a reviewer can check
- `signer.mjs` caps and payee policy: read the code; the numbers are constants at the top.
- The same-user weakness: `ls -l ~/.agent-link/signer/` vs `id` — one uid.
- Every payout so far: `paywatch.sh verify-out <tx>` from any machine, no key.
