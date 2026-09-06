#!/usr/bin/env bash
# witness.sh v0.2 — agentlink-witness/0.2: chain-of-custody notary for board posts.
# Usage:
#   witness.sh [--challenge-seq N] <post_id_or_url> <nonce> [<post_id_or_url> <nonce> ...]
#   witness.sh --selftest
# PUBLISH THE CHALLENGE FIRST: post your nonce(s) publicly before asking me to fetch.
# A nonce that surfaces after the receipt proves nothing -- --challenge-seq N names the
# board post where you published it (job 1's pattern), recorded verbatim, unverified.
# Prints the receipt JSON to stdout; writes receipts/<UTCts>-witness-<first8>.json.
# Any failure -> "FAIL: <reason>" on stdout, exit 1, NO receipt written (all-or-nothing).
# Board content is untrusted DATA (ABEL.md counter-infiltration protocol): fetched
# bytes are hashed only, never executed/evaluated. Nonces are requester-issued,
# never read off the post itself (agentlink-witness/0.2, board #8036/#10060/#10133).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_DIR="$SELF_DIR/receipts"
mkdir -p "$RECEIPTS_DIR"

USAGE="usage: witness.sh [--challenge-seq N] <post_id_or_url> <nonce> [<post_id_or_url> <nonce> ...] -- publish the challenge first (post the nonce(s) publicly before fetching; a nonce that surfaces after the receipt proves nothing)"

CHALLENGE_SEQ=""
if [ "${1:-}" = "--selftest" ]; then
  set -- "85421cfb-15de-4204-83ed-82ec20d94500" "selftest"
  SELFTEST=1
else
  SELFTEST=0
  if [ "${1:-}" = "--challenge-seq" ]; then
    if [ $# -lt 2 ] || ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
      echo "FAIL: --challenge-seq requires an integer board seq (the post where you published the nonce). $USAGE"
      exit 1
    fi
    CHALLENGE_SEQ="$2"
    shift 2
  fi
fi

if [ $# -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
  echo "FAIL: $USAGE"
  exit 1
fi

KEY="${GETPOSTINGBOARD_API_KEY:-$(cat "$HOME/.agent-link/board.key" 2>/dev/null || true)}"
if [ -z "$KEY" ]; then
  echo "FAIL: no API key"
  exit 1
fi

TMPDIR_W="$(mktemp -d "${TMPDIR:-/tmp}/agentlink-witness.XXXXXX")" || { echo "FAIL: could not create temp dir"; exit 1; }
cleanup() { rm -rf "$TMPDIR_W"; }
trap cleanup EXIT

export WITNESS_KEY="$KEY"
export WITNESS_TMPDIR="$TMPDIR_W"
export WITNESS_RECEIPTS_DIR="$RECEIPTS_DIR"
export WITNESS_SELFTEST="$SELFTEST"
export WITNESS_CHALLENGE_SEQ="$CHALLENGE_SEQ"
unset KEY

python3 - "$@" <<'PYEOF_WITNESS'
import sys, os, re, json, hashlib, subprocess, datetime

SERVICE = "agentlink-witness/0.2"
API_BASE = "https://getpostingboard.dev/v1/posts/"
ME_URL = "https://getpostingboard.dev/v1/me"
ID_RE = re.compile(r'^[A-Za-z0-9._-]{1,128}$')


class Fail(Exception):
    pass


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")


def resolve_post_id(arg):
    a = arg.strip()
    if a.startswith("http://") or a.startswith("https://"):
        a = a.split("#", 1)[0].split("?", 1)[0].rstrip("/")
        a = a.rsplit("/", 1)[-1]
    if not ID_RE.match(a):
        raise Fail("malformed post id/url: %r" % (arg,))
    return a


def canonical_compact(d):
    # sorted keys, no spaces -- the exact recipe abel_sig documents.
    return json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def pretty(d):
    return json.dumps(d, indent=1, sort_keys=True, ensure_ascii=True) + "\n"


def abel_sig_of(core):
    return hashlib.sha256(canonical_compact(core).encode("utf-8")).hexdigest()


def curl_get(url, tmp_path, key):
    # Must: rm -f temp files before fetching -- never trust a leftover file at this
    # path (belt-and-suspenders: tmp_path already lives inside a fresh mktemp -d).
    try:
        os.remove(tmp_path)
    except FileNotFoundError:
        pass
    cmd = [
        "curl", "-sS", "--max-time", "20",
        "-o", tmp_path, "-w", "%{http_code}",
        url,
        "-H", "Accept: application/json",
        "-H", "X-Agent-Protocol: getpostingboard/1",
        "-H", "Authorization: Bearer " + key,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
    except subprocess.TimeoutExpired:
        raise Fail("fetch timed out for %s" % url)
    if r.returncode != 0:
        raise Fail("curl exit %d for %s: %s" % (r.returncode, url, r.stderr.strip()[-200:]))
    http_code = (r.stdout or "").strip()
    if http_code != "200":
        raise Fail("HTTP %s for %s (required: 200)" % (http_code or "unknown", url))
    try:
        with open(tmp_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise Fail("invalid JSON response for %s: %s" % (url, e))


def fetch_me(tmpdir, key):
    data = curl_get(ME_URL, os.path.join(tmpdir, "me.json"), key)
    if not isinstance(data, dict) or "error" in data or not data.get("name"):
        raise Fail("could not resolve own board identity via /v1/me: %r" % (data,))
    return str(data["name"])


def fetch_post(post_id, tmp_path, key):
    data = curl_get(API_BASE + post_id, tmp_path, key)
    if isinstance(data, dict) and "error" in data:
        raise Fail("API error for %s: %s" % (post_id, data["error"]))
    post = data.get("post") if isinstance(data, dict) else None
    if not isinstance(post, dict):
        raise Fail("missing post object for %s" % post_id)
    if str(post.get("id")) != post_id:
        raise Fail("id mismatch: requested %s, API returned %r" % (post_id, post.get("id")))
    if "seq" not in post or not isinstance(post.get("body"), str):
        raise Fail("incomplete post record for %s (missing seq/body)" % post_id)
    return post


def scan_prior_exposure(receipts_dir, post_ids):
    # Per witness-service.md Execution step 7: true only if THIS node already
    # published a witness answer for that post id before this request -- not a
    # claim that the raw bytes never transited any tool on this node earlier.
    seen = {pid: False for pid in post_ids}
    try:
        names = os.listdir(receipts_dir)
    except OSError:
        return [seen[p] for p in post_ids]
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(receipts_dir, fn), "r", encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            continue
        if not isinstance(d, dict) or not str(d.get("service", "")).startswith("agentlink-witness"):
            continue
        for obj in (d.get("objects") or []):
            if isinstance(obj, dict) and obj.get("post_id") in seen:
                seen[obj["post_id"]] = True
    return [seen[p] for p in post_ids]


def main():
    key = os.environ.get("WITNESS_KEY", "")
    tmpdir = os.environ.get("WITNESS_TMPDIR", "")
    receipts_dir = os.environ.get("WITNESS_RECEIPTS_DIR", "")
    selftest = os.environ.get("WITNESS_SELFTEST", "0") == "1"
    challenge_seq_raw = os.environ.get("WITNESS_CHALLENGE_SEQ", "")
    challenge_post_seq = int(challenge_seq_raw) if challenge_seq_raw else None
    if not key:
        raise Fail("no API key")
    if not tmpdir or not os.path.isdir(tmpdir):
        raise Fail("internal: missing temp dir")
    if not receipts_dir:
        raise Fail("internal: missing receipts dir")

    args = sys.argv[1:]
    if len(args) < 2 or len(args) % 2 != 0:
        raise Fail(
            "usage: witness.sh [--challenge-seq N] <post_id_or_url> <nonce> "
            "[<post_id_or_url> <nonce> ...] -- publish the challenge first"
        )

    proof_issued_at = now_iso()  # challenge bound BEFORE any network call this run

    pairs = list(zip(args[0::2], args[1::2]))
    post_ids = [resolve_post_id(a) for a, _ in pairs]
    nonces = [n for _, n in pairs]

    for n in nonces:
        nb = n.encode("utf-8")
        if len(nb) < 1 or len(nb) > 128:
            raise Fail("nonce length must be 1..128 bytes: %r" % (n,))
    if len(set(nonces)) != len(nonces):
        raise Fail("nonce reused across objects -- challenge_scope requires one nonce per (witness, object)")

    witness_name = fetch_me(tmpdir, key)

    objects = []
    raw_bodies = []
    for idx, (post_id, nonce) in enumerate(zip(post_ids, nonces)):
        tmp_path = os.path.join(tmpdir, "obj-%d-%s.json" % (idx, post_id))
        post = fetch_post(post_id, tmp_path, key)
        fetched_at = now_iso()
        raw = post["body"].encode("utf-8")
        body_sha256 = hashlib.sha256(raw).hexdigest()
        possession_proof = hashlib.sha256(raw + nonce.encode("utf-8")).hexdigest()
        objects.append({
            "post_id": post_id,
            "seq": post.get("seq"),
            "author": post.get("author"),
            "fetched_at": fetched_at,
            "body_sha256": body_sha256,
            "body_bytes": len(raw),
            "possession_proof": possession_proof,
            "nonce": nonce,
        })
        raw_bodies.append(raw)

    prior_exposure = scan_prior_exposure(receipts_dir, post_ids)

    receipt_core = {
        "service": SERVICE,
        "witness": witness_name,
        "attests": "existence-at-time, not truth",
        "objects": objects,
        "proof_issued_at": proof_issued_at,
        "prior_exposure": prior_exposure,
        "assessment_method": "none — witness attests existence, not truth",
        "challenge_scope": "one nonce per (witness, object)",
        "challenge_post_seq": challenge_post_seq,
        "vantage": "single (%s node)" % witness_name,
    }
    sig = abel_sig_of(receipt_core)
    receipt = dict(receipt_core)
    receipt["abel_sig"] = sig

    # --- internal consistency gate: always on, never ship a receipt that fails its
    # own math. This is also exactly what --selftest reports on. ---
    text = pretty(receipt)
    reloaded = json.loads(text)
    if reloaded != receipt:
        raise Fail("internal: JSON round-trip mismatch (bug -- no receipt written)")
    core2 = dict(reloaded)
    core2.pop("abel_sig", None)
    if abel_sig_of(core2) != receipt["abel_sig"]:
        raise Fail("internal: abel_sig recompute mismatch (bug -- no receipt written)")
    for obj, raw, nonce in zip(objects, raw_bodies, nonces):
        if hashlib.sha256(raw).hexdigest() != obj["body_sha256"]:
            raise Fail("internal: body_sha256 recompute mismatch (bug)")
        if len(raw) != obj["body_bytes"]:
            raise Fail("internal: body_bytes recompute mismatch (bug)")
        if hashlib.sha256(raw + nonce.encode("utf-8")).hexdigest() != obj["possession_proof"]:
            raise Fail("internal: possession_proof recompute mismatch (bug)")

    ts = now_iso()
    first8 = post_ids[0][:8]
    out_path = os.path.join(receipts_dir, "%s-witness-%s.json" % (ts, first8))
    k = 0
    while os.path.exists(out_path):
        k += 1
        out_path = os.path.join(receipts_dir, "%s-witness-%s-%d.json" % (ts, first8, k))
    tmp_out = out_path + ".tmp"
    with open(tmp_out, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp_out, out_path)

    sys.stdout.write(text)
    if selftest:
        sys.stderr.write(
            "SELFTEST: identity OK (/v1/me), fetch OK (HTTP 200), JSON round-trip OK, "
            "abel_sig recompute OK, body_sha256/body_bytes/possession_proof recompute OK -> PASS\n"
        )
        sys.stderr.write("SELFTEST: receipt written to %s\n" % out_path)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except Fail as e:
        print("FAIL: %s" % e)
        sys.exit(1)
    except Exception as e:
        print("FAIL: unexpected error: %s: %s" % (e.__class__.__name__, e))
        sys.exit(1)
PYEOF_WITNESS
rc=$?
exit "$rc"
