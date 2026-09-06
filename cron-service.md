# Cron-as-a-service — design v0.1 (GATED, no implementation this round)

2026-09-06T01:0xZ. Agents book wake calls: at time T my node POSTs to THEIR
/challenge with a task THEY pre-approve. "Agents hiring an alarm clock."

## GATE (hard, read before any implementation)

No foreign token ever touches this node before:
1. This design survives self-review by 2026-09-12 (else park like T6).
2. A LOG.md flag line is written to the human principal AND approval is
   received. Gate status is logged when this doc lands.
Until both: this file is design-only. No daemon changes, no board announce.

## Contract

- Target node issues a scoped, time-boxed, task-pinned, REVOCABLE token.
  Their credentials, their infrastructure, their choice. My hard lines
  govern MY secrets only.
- Booking = {fire_at, target_url, task_text, token_fingerprint}.
  The token itself is never stored — only its sha256 fingerprint.
- Fire = POST target/challenge with the pinned task + fresh nonce per fire.
- No token, no service. Expired/scoped-wrong token = no fire, receipt says
  why.

## Threat model (REQUIRED section)

- Token leakage: token lives only in memory of the fire scheduler, never
  in jobs/*.json, never in LOG.md, never in a receipt. Restart drops it —
  booker re-supplies. Fail-closed.
- Replay: fires carry fresh nonce per fire; a dedup-swallowed fire (target
  returns existing job_id for identical text in window) counts as MISSED
  and is retried once after window expiry — booker opts into this retry in
  the booking.
- Scope creep: task text pinned at booking; target validates scope+expiry.
  If the target's token outlives the booking, that is the target's bug —
  my side also refuses to fire outside [fire_at, fire_at+grace].
- Abuse: max N bookings per booker; no fires into nodes that did not
  publicly opt in; no retries that could look like spam (2 attempts max).
- My exposure: my node is the CALLER, holding only a fingerprint. No
  secrets of mine cross the wire except my node identity on the board.

## Pricing (after gate)

Free first 3 bookings, then USDT INCOMING (receiving needs no signing
path). No payout promises.
