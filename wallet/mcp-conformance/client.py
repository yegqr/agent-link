#!/usr/bin/env python3
"""AgentWallet pinned-interface checks; Python 3.10+ stdlib. MIT, Pilot Finch."""
import argparse
import json
import math
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading

BASE = Path(__file__).resolve().parent


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def run(args):
    sequence = read_json(BASE / "sequence.json")
    expected = read_json(BASE / "expected.json")
    inbox, errors, transcript = queue.Queue(), [], []
    checks = []
    with tempfile.TemporaryDirectory(prefix="agentwallet-mcp-") as home:
        env = dict(os.environ, HOME=home, USERPROFILE=home)
        command = [args.node, str(args.server.resolve()), "--address",
                   expected["address"], "--signer-socket", str(Path(home) / "unused.sock"),
                   "--rpc", "http://127.0.0.1:1" if args.offline else args.rpc]
        child = subprocess.Popen(command, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, encoding="utf-8", env=env, cwd=home)

        def read_stdout():
            for line in child.stdout:
                inbox.put(line)
            inbox.put(None)

        def read_stderr():
            for line in child.stderr:
                errors.append(line.rstrip())

        reader = threading.Thread(target=read_stdout, daemon=True)
        err_reader = threading.Thread(target=read_stderr, daemon=True)
        reader.start()
        err_reader.start()
        try:
            for step in sequence:
                if args.offline and step.get("online_only"):
                    continue
                request = step["request"]
                transcript.append({"direction": "client", "message": request})
                child.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
                child.stdin.flush()
                if "id" not in request:
                    continue
                line = inbox.get(timeout=args.timeout)
                require(line is not None, "server exited before response: " + str(errors[-3:]))
                response = json.loads(line)
                transcript.append({"direction": "server", "message": response})
                require(isinstance(response, dict), "response must be an object")
                require(response.get("jsonrpc") == "2.0", "JSON-RPC version")
                require(response.get("id") == request["id"], "unexpected response id")
                require("result" in response and "error" not in response, "expected success result")
                result = response["result"]
                check = step["check"]
                if check == "initialize":
                    for key, value in expected["initialize"].items():
                        require(result.get(key) == value, "initialize field: " + key)
                elif check == "tools":
                    tools = result.get("tools", [])
                    require([t["name"] for t in tools] == list(expected["schemas"]),
                            "tools/list must contain exactly the four pinned tools")
                    for tool in tools:
                        require(tool.get("inputSchema") == expected["schemas"][tool["name"]],
                                "inputSchema changed: " + tool["name"])
                else:
                    require(not result.get("isError", False), "tool reported isError")
                    content = result.get("content")
                    require(isinstance(content, list) and len(content) == 1,
                            "expected exactly one tool content item")
                    require(content[0].get("type") == "text", "expected text content")
                    data = json.loads(content[0]["text"])
                    if check == "address":
                        require(data == {"address": expected["address"]}, "address result")
                    elif check == "balance":
                        require(data.get("address") == expected["address"], "balance address")
                        for key in ("usdt", "eth", "outgoing_tx_count"):
                            require(number(data.get(key)), "balance number: " + key)
                        require(type(data.get("is_contract")) is bool, "is_contract shape")
                        for key in ("rpc", "at"):
                            require(isinstance(data.get(key), str), "balance string: " + key)
                    elif check == "verify_tx":
                        for key, value in expected["verify_tx"].items():
                            if key == "block":
                                continue  # Recorded example; runtime comparison is by shape.
                            require(type(data.get(key)) is type(value) and data[key] == value,
                                    "receipt fixture field: " + key)
                        require(type(data.get("block")) is int, "receipt block shape")
                        transfers = data.get("usdt_transfers")
                        require(isinstance(transfers, list), "transfers shape")
                        require(any(t.get("to", "").lower() == expected["recipient"].lower()
                                    and t.get("usdt") == 0.1 for t in transfers),
                                "expected recipient and amount in the same transfer")
                    else:
                        raise AssertionError("unknown fixture check: " + check)
                checks.append(check)
            child.stdin.close()
        finally:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            reader.join(timeout=1)
            err_reader.join(timeout=1)
            if args.transcript:
                args.transcript.write_text(json.dumps(transcript, indent=2) + "\n", encoding="utf-8")
        extras = []
        while not inbox.empty():
            line = inbox.get_nowait()
            if line is not None:
                extras.append(line)
        require(not extras, "unexpected extra stdout/notification response")
    return {"ok": True, "mode": "offline" if args.offline else "online",
            "checks": checks, "requests": sum(x["direction"] == "client" for x in transcript)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--server", type=Path, default=BASE.parent / "mcp-server.mjs")
    parser.add_argument("--node", default=shutil.which("node") or "node")
    parser.add_argument("--rpc", default="https://ethereum-rpc.publicnode.com")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--transcript", type=Path)
    options = parser.parse_args()
    try:
        print(json.dumps(run(options), sort_keys=True))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc) or type(exc).__name__}))
        raise SystemExit(1)
