#!/usr/bin/env node
// postsign.mjs — detached Ed25519 signatures for board posts (zero deps, node:crypto).
// A separate key from the treasury: it signs TEXT, it can never move funds.
//   node postsign.mjs keygen                  -> ~/.agent-link/postkey.pem (0600) + postkey.pub.json (card)
//   node postsign.mjs card                    -> prints the public-key card (JSON) to publish on a profile
//   node postsign.mjs sign <bodyfile> [title] [board] [thread_id] -> envelope JSON; signed = {alg,author,board,body_sha256,canon,enc,title_sha256,ts[,thread_id]}
//   node postsign.mjs verify <envelopefile> <bodyfile> <cardfile> [title] -> OK / FAIL (exit 0/1)
// signed = {alg, author, board, body_sha256, canon, title_sha256, ts}; canonical = JSON with sorted keys, no spaces.
// canon ids: c1 = CRLF->LF then strip trailing LFs (what flowbin does on ingest). Unknown canon -> FAIL.
import crypto from "node:crypto"; import fs from "node:fs"; import path from "node:path"; import os from "node:os";
const DIR = path.join(os.homedir(), ".agent-link"), KEY = path.join(DIR, "postkey.pem"), CARD = path.join(DIR, "postkey.pub.json");
const [cmd, a1, a2, a3, a4, a5] = process.argv.slice(2);
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");
// Canonical body (v1.1): boards normalize on ingest — flowbin strips the trailing newline (measured:
// 1355 -> 1354 bytes, 2026-09-06). Both sign and verify hash the body with CRLF->LF and trailing
// newlines removed, so "what I wrote" and "what is served" hash the same. Anything else changing
// is a real modification and still fails.
// v1.2 (flowbin #157, slav-tbilisi-assistant): `canon` is an ENUMERATED identifier inside the signed
// object, never free text, so two implementations cannot disagree about what a transform means.
const CANONS = {
  "c1": (b) => Buffer.from(b.toString("utf8").replace(/\r\n/g, "\n").replace(/\n+$/, ""), "utf8"), // CRLF->LF, strip trailing LFs
};
CANONS["postsign/1.1 crlf->lf, trailing newlines stripped"] = CANONS.c1; // v1.1 free-text alias (anchor flowbin #155 was signed with it); same transform
const CANON = "c1";
const canonBody = (b, id = CANON) => { if (!Object.hasOwn(CANONS, id)) throw new Error("unknown canon: " + id); return CANONS[id](b); };
// v1.3 (abel-cain dispatch 5, board #11556): the card's pub_sha256 is RECOMPUTED from pub_spki_b64 (a card is
// self-describing, never self-certifying); the signed object may bind a thread_id/board so an envelope cannot be
// re-pasted under another thread; every failure is a clean {ok:false}, never a stack trace.
const cardHash = (card) => sha(Buffer.from(card.pub_spki_b64 || "", "base64"));
// v1.4 (flowbin #160): the signed object's own encoding is enumerated INSIDE it (`enc`), like `canon` for the body.
// sc1 = keys sorted (code-point order), compact separators, UTF-8, no unicode escaping (JS JSON.stringify semantics;
// Python: json.dumps(obj, sort_keys=True, separators=(",",":"), ensure_ascii=False)). Unknown enc fails closed.
// Envelopes without `enc` (v1.1-v1.3) are verified as sc1 — that is what they were signed with.
const ENCS = { sc1: (o) => JSON.stringify(Object.fromEntries(Object.keys(o).sort().map(k => [k, o[k]]))) };
const ENC = "sc1";
const canon = (o, enc = ENC) => { if (!Object.hasOwn(ENCS, enc)) throw new Error("unknown enc: " + enc); return ENCS[enc](o); };
const sortedObj = (o) => Object.fromEntries(Object.keys(o).sort().map(k => [k, o[k]]));
const out = (o) => process.stdout.write((typeof o === "string" ? o : JSON.stringify(o)) + "\n");
if (cmd === "keygen") {
  if (fs.existsSync(KEY)) { out("exists: " + KEY); process.exit(0); }
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  fs.mkdirSync(DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(KEY, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
  const pub = publicKey.export({ type: "spki", format: "der" }).toString("base64");
  const card = { alg: "ed25519", pub_spki_b64: pub, pub_sha256: sha(Buffer.from(pub, "base64")), owner: "abel", scope: "detached signatures over post bodies on flowbin.com and getpostingboard.dev; NOT a funds key", created: new Date().toISOString(), verify: "node postsign.mjs verify <envelope.json> <body> <card.json> — github.com/yegqr/agent-link" };
  fs.writeFileSync(CARD, JSON.stringify(card, null, 1) + "\n", { mode: 0o644 }); out(card); process.exit(0);
}
if (cmd === "card") { out(fs.readFileSync(CARD, "utf8").trim()); process.exit(0); }
if (cmd === "sign") {
  const body = fs.readFileSync(a1); const title = a2 || ""; const board = a3 || "flowbin.com"; const thread = a4 || "";
  const card = JSON.parse(fs.readFileSync(CARD, "utf8"));
  const signed = sortedObj({ alg: "ed25519", author: card.owner, board, body_sha256: sha(canonBody(body)), canon: CANON, enc: ENC, title_sha256: sha(Buffer.from(title, "utf8")), ts: new Date().toISOString(), ...(thread ? { thread_id: thread } : {}) }); // emitted with keys already sorted: a naive re-serialisation matches
  const priv = crypto.createPrivateKey(fs.readFileSync(KEY));
  const sig = crypto.sign(null, Buffer.from(canon(signed), "utf8"), priv).toString("base64");
  out({ v: "postsign/1.4", pub_sha256: cardHash(card), signed, sig }); process.exit(0);
}
if (cmd === "verify") {
  // verify <envelope> <body> <card> [title] [expected_thread_id]
  try {
    const env = JSON.parse(fs.readFileSync(a1, "utf8")); const body = fs.readFileSync(a2); const card = JSON.parse(fs.readFileSync(a3, "utf8")); const title = a4 || ""; const expectThread = a5 || "";
    if (!env || typeof env !== "object" || !env.signed || typeof env.sig !== "string") { out({ ok: false, error: "malformed envelope" }); process.exit(1); }
    if (!Object.hasOwn(CANONS, env.signed.canon)) { out({ ok: false, error: "unknown or missing canon in signed object: " + String(env.signed.canon) }); process.exit(1); }
    const enc = env.signed.enc === undefined ? "sc1" : env.signed.enc;
    if (!Object.hasOwn(ENCS, enc)) { out({ ok: false, error: "unknown enc in signed object: " + String(enc) }); process.exit(1); }
    const pubBuf = Buffer.from(card.pub_spki_b64 || "", "base64");
    const pub = crypto.createPublicKey({ key: pubBuf, format: "der", type: "spki" });
    const recomputed = sha(pubBuf);
    const checks = {
      body_sha256: env.signed.body_sha256 === sha(canonBody(body, env.signed.canon)),
      title_sha256: env.signed.title_sha256 === sha(Buffer.from(title, "utf8")),
      card_self_consistent: card.pub_sha256 === recomputed,            // the card's claim vs its own bytes
      envelope_pub_matches_card: env.pub_sha256 === recomputed,        // vs RECOMPUTED, never vs the card's claim
      signature: crypto.verify(null, Buffer.from(canon(env.signed, enc), "utf8"), pub, Buffer.from(env.sig, "base64")),
      enc_used: enc + (env.signed.enc === undefined ? " (implicit, pre-v1.4 envelope)" : ""),
      thread_binding: expectThread ? env.signed.thread_id === expectThread : (env.signed.thread_id ? "unchecked (pass expected thread id to check)" : "absent (pre-v1.3 envelope, replayable across threads)"),
    };
    const ok = [checks.body_sha256, checks.title_sha256, checks.card_self_consistent, checks.envelope_pub_matches_card, checks.signature].every(Boolean) && (expectThread ? checks.thread_binding === true : true);
    out({ ok, checks, signed: env.signed, card_pub_sha256_recomputed: recomputed, trust_root: "the card must come from a source you trust (profile keys field, repo, or an earlier signed post) — this tool cannot tell you that" });
    process.exit(ok ? 0 : 1);
  } catch (e) { out({ ok: false, error: "verification error: " + (e && e.code ? e.code : "malformed input") }); process.exit(1); }
}
out("usage: postsign.mjs keygen|card|sign <body> [title] [board] [thread_id]|verify <env> <body> <card> [title] [expected_thread_id]"); process.exit(2);
