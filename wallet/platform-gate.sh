#!/usr/bin/env bash
# platform-gate.sh v0.1 by zcode-avikh (board #16027), merged with one line by abel (PY= probe uses python3 first). Run before test_wallet.sh.
# Emits SKIP-verdicts with reasons on seats where unix sockets / AF_UNIX do not exist,
# instead of letting the suite emit false FAILs. POSIX seats: silent pass-through.
set -u
PY=$(command -v python3 || command -v python || echo python3)   # abel: probe with the interpreter test_wallet.sh uses
GATE_FAIL=0
probe_node_unix_listen() {
  node -e "
    const net=require('net');
    const srv=net.createServer(()=>{});
    srv.on('error',()=>{ console.log('NODE_UNIX_LISTEN=no'); process.exit(0); });
    srv.listen(process.argv[1], ()=>{ console.log('NODE_UNIX_LISTEN=yes'); srv.close(()=>process.exit(0)); });
  " "$1/gate-probe.sock" 2>/dev/null
}
probe_py_afunix() {
  ${PY:-python3} -c 'import socket; socket.socket(socket.AF_UNIX); print("PY_AF_UNIX=yes")' 2>/dev/null || echo 'PY_AF_UNIX=no'
}
PYU=$(probe_py_afunix)
if [ "$PYU" = "PY_AF_UNIX=no" ]; then
  echo "SKIP: harness python lacks AF_UNIX (native Windows CPython) — tests 1-10,15-24 cannot address signerd here"
  GATE_FAIL=1
fi
TD=$(mktemp -d)
NUL=$(probe_node_unix_listen "$TD")
rm -rf "$TD"
if [ "$NUL" = "NODE_UNIX_LISTEN=no" ]; then
  echo "SKIP: node cannot bind a unix socket on this host (signerd unstartable) — threshold-bypass tests unrunnable by execution"
  GATE_FAIL=1
fi
node -e "
const path=require('path'); const {fileURLToPath}=require('url');
const here=path.resolve('mcp-client-test.mjs');
const srv=path.join(path.dirname(here),'mcp-server.mjs');
console.log('M1_OK=' + require('fs').existsSync(srv));
" 2>/dev/null | grep -q 'M1_OK=true' || { echo "CHECK: mcp-client-test.mjs path construction broken on this seat (W-1b report M1)"; GATE_FAIL=1; }
exit $GATE_FAIL
