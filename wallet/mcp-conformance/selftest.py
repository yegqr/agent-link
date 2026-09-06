#!/usr/bin/env python3
"""Offline acceptance tests for client.py, using an authored protocol fixture. MIT."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

base = Path(__file__).resolve().parent
expected = json.loads((base / "expected.json").read_text())
cases = {"baseline": None, "extra_send": "wallet.send", "extra_swap": "wallet.swap",
         "schema_change": "schema_change"}
results = []
with tempfile.TemporaryDirectory(prefix="mcp-client-test-") as folder:
    fixture = Path(folder) / "server.mjs"
    for name, change in cases.items():
        fixture.write_text('''import readline from "node:readline";
const expected = EXPECTED;
const change = CHANGE;
const tools = Object.entries(expected.schemas).map(([name,inputSchema])=>({name,inputSchema}));
if (change === "schema_change") tools[0].inputSchema = {type:"string"};
else if (change) tools.push({name:change,inputSchema:{type:"object",properties:{}}});
for await (const line of readline.createInterface({input:process.stdin})) {
  const request=JSON.parse(line);
  if (request.id === undefined) continue;
  const result = request.method === "initialize" ? expected.initialize :
    request.method === "tools/list" ? {tools} :
    {content:[{type:"text",text:JSON.stringify({address:expected.address})}]};
  process.stdout.write(JSON.stringify({jsonrpc:"2.0",id:request.id,result})+"\\n");
}
'''.replace("EXPECTED", json.dumps(expected)).replace("CHANGE", json.dumps(change)))
        run = subprocess.run([sys.executable, str(base / "client.py"), "--offline",
                              "--server", str(fixture), "--timeout", "5"],
                             capture_output=True, text=True, timeout=15)
        output = json.loads(run.stdout)
        assert (run.returncode == 0) == (change is None), (name, run.stdout, run.stderr)
        assert output["ok"] == (change is None), output
        if change is not None:
            assert "tools/list" in output["error"] or "inputSchema" in output["error"], output
        results.append({"case": name, "exit_code": run.returncode, "result": output})
print(json.dumps({"ok": True, "cases": results}, indent=2))
