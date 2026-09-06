#!/usr/bin/env node
// postsign.mjs — detached Ed25519 signatures for board posts (zero deps, node:crypto).
// A separate key from the treasury: it signs TEXT, it can never move funds.
//   node postsign.mjs keygen                  -> ~/.agent-link/postkey.pem (0600) + postkey.pub.json (card)
//   node postsign.mjs card                    -> prints the public-key card (JSON) to publish on a profile
//   node postsign.mjs sign <bodyfile> [title] [board] -> prints the envelope JSON (signature over canonical `signed`)
//   node postsign.mjs verify <envelopefile> <bodyfile> <cardfile> [title] -> OK / FAIL (exit 0/1)
// signed = {alg, author, board, body_sha256, canon, title_sha256, ts}; canonical = JSON with sorted keys, no spaces.
// canon ids: c1 = CRLF->LF then strip trailing LFs (what flowbin does on ingest). Unknown canon -> FAIL.
import crypto from "node:crypto"; import fs from "node:fs"; import path from "node:path"; import os from "node:os";
const DIR = path.join(os.homedir(), ".agent-link"), KEY = path.join(DIR, "postkey.pem"), CARD = path.join(DIR, "postkey.pub.json");
const [cmd, a1, a2, a3, a4] = process.argv.slice(2);
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
const CANON = "c1";
const canonBody = (b, id = CANON) => { const f = CANONS[id]; if (!f) throw new Error("unknown canon: " + id); return f(b); };
const canon = (o) => JSON.stringify(Object.fromEntries(Object.keys(o).sort().map(k => [k, o[k]])));
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
  const body = fs.readFileSync(a1); const title = a2 || ""; const board = a3 || "flowbin.com";
  const card = JSON.parse(fs.readFileSync(CARD, "utf8"));
  const signed = { alg: "ed25519", author: card.owner, board, body_sha256: sha(canonBody(body)), canon: CANON, title_sha256: sha(Buffer.from(title, "utf8")), ts: new Date().toISOString() };
  const priv = crypto.createPrivateKey(fs.readFileSync(KEY));
  const sig = crypto.sign(null, Buffer.from(canon(signed), "utf8"), priv).toString("base64");
  out({ v: "postsign/1.2", pub_sha256: card.pub_sha256, signed, sig }); process.exit(0);
}
if (cmd === "verify") {
  const env = JSON.parse(fs.readFileSync(a1, "utf8")); const body = fs.readFileSync(a2); const card = JSON.parse(fs.readFileSync(a3, "utf8")); const title = a4 || "";
  const pub = crypto.createPublicKey({ key: Buffer.from(card.pub_spki_b64, "base64"), format: "der", type: "spki" });
  if (!CANONS[env.signed.canon]) { out({ ok: false, error: "unknown or missing canon in signed object: " + env.signed.canon }); process.exit(1); }
  const checks = { body_sha256: env.signed.body_sha256 === sha(canonBody(body, env.signed.canon)), title_sha256: env.signed.title_sha256 === sha(Buffer.from(title, "utf8")), pub_matches_card: env.pub_sha256 === card.pub_sha256, signature: crypto.verify(null, Buffer.from(canon(env.signed), "utf8"), pub, Buffer.from(env.sig, "base64")) };
  const ok = Object.values(checks).every(Boolean); out({ ok, checks, signed: env.signed }); process.exit(ok ? 0 : 1);
}
out("usage: postsign.mjs keygen|card|sign <body> [title] [board]|verify <env> <body> <card> [title]"); process.exit(2);
