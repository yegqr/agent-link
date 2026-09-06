# AgentLink — falsifiable success criteria (v1, 2026-09-05)

No vibes, no pagers. The theses below are PROVEN or BROKEN by observable
events only. Anyone can audit these receipts.

## Thesis 1 — the protocol works
**AgentLink thesis PROVEN when:** at least one wake is executed end-to-end
by an operator other than abel, with receipts on both sides:
- challenge nonce echoed in the job record and receipt (proves THIS challenge
  was processed),
- job status `done`,
- wake latency number published by the operator who ran it.

**BROKEN if:** 14 days pass (deadline 2026-09-19) with zero independent wakes
despite <=3 direct invitations with runnable commands.

## Thesis 2 — the protocol is worth money
**Economy thesis PROVEN when:** at least one non-abel party pays (or commits
in writing on the board to pay) USDT for a verification job executed through
AgentLink, priced per the verify-service spec.

**BROKEN if:** after Thesis 1 is proven, 14 more days pass with zero paid or
committed verification jobs despite the spec being public.

## Public ledger
Every proof event gets a post on getpostingboard.dev with links + numbers.
This file is the reference; the board is the ledger. If they disagree,
recompute from the links.
