# AgentWallet MCP interface and reproducible client

Pilot Finch, 2026-09-06. MIT.

Target: `wallet/mcp-server.mjs` at commit
`c1b69d0080303c33f3d00fa7a6d5c565bf40ff68`, SHA-256
`d880d071d70378ba7e0ad7deee8d5ba52cc2ec55211557ca031554017b45ca85`.
This is a check of that pinned ordinary interface, not general MCP certification
or a security review. It neither changes the server nor implements transactions.

## Run

Place this file at `wallet/MCP-INTERFACE.md` and the four accompanying files in
`wallet/mcp-conformance/`: `client.py`, `sequence.json`, `expected.json`, `selftest.py`.
Requirements: Python 3.10+ and Node available on PATH, standard libraries only.

```sh
python3 wallet/mcp-conformance/client.py --offline --transcript offline.json
python3 wallet/mcp-conformance/client.py --transcript online.json
python3 wallet/mcp-conformance/selftest.py
```

`--node /absolute/path/to/node` and `--server /absolute/path/to/mcp-server.mjs`
override executable/file discovery. Online defaults to
`--rpc https://ethereum-rpc.publicnode.com`; `--timeout 90` is per response.
The pinned server has its own RPC fallback list; the supplied URL is not its
exclusive endpoint. Network failure makes the online run fail; it never silently
substitutes fixture values for live results. Exit 0 means pass, exit 1 means fail.

The client spawns the server with a temporary HOME/USERPROFILE, an explicit dummy
address `0x1111111111111111111111111111111111111111` and an unused temporary socket
path. The temporary directory is deleted at the end. No wallet is created.
The client never calls `wallet.policy`, the signer, approvals, send or swap.

Offline sends initialize, initialized, tools/list and wallet.address only; the RPC
argument is an unused loopback endpoint. Online adds balance for the dummy address
and the fixed historical verify_tx fixture. All chain operations are public reads.
stdout/stderr are separate; JSON messages are framed by physical newlines. The
optional transcript records the actual requests and responses, not predictions.

## Actual messages

`sequence.json` contains complete request messages and their check names.
`expected.json` contains exact deterministic result fields and live input schemas.
The client compares dictionary structure rather than whitespace or JSON key order.
For this pinned server, an unexpected notification/response is a failure; a general
MCP client would dispatch notifications and follow tools/list pagination. This
server does not emit those notifications or return a nextCursor.

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"pilot-finch-conformance","version":"1.0.0"}}}
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"agentwallet","version":"0.1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

There is no response to initialized. The tools/list response is
`{"jsonrpc":"2.0","id":2,"result":{"tools":[...]}}`.
The exact ordered names are wallet.address, wallet.balance, wallet.verify_tx,
wallet.policy. Names and inputSchema are checked against expected.json. Thus adding
wallet.send or wallet.swap fails; description wording is not compared.

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wallet.address","arguments":{}}}
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"address\":\"0x1111111111111111111111111111111111111111\"}"}]}}
```

Tool output is JSON encoded inside a text content item. The client decodes both
layers, rejects JSON-RPC error responses and result.isError, and requires the
response ID to match the outstanding request. It sends each request only after
receiving the previous response, with unique integer IDs. The pinned server omits
isError on success, which the client accepts. Its error envelopes are not normalized
or presented as a complete conformance test of all MCP error cases.

The online balance check compares number/string/boolean shapes and the requested
address, without freezing balances, timestamp or nonce. Per the acceptance terms,
the client checks verify_tx.block by integer shape, not value. The fixture records
the independently observed historical value as an example: transaction
`0x0b85c754d9a92983f7e17073f8d4ed73a45889d8926e24ea8df7cd65631e71b9`,
status 1, block 25918159, expected_to
`0xD7e18Fc120F082EB5002138D6967135A89Ba842e`, expected_usdt 0.1,
to_match true and amount_match true. The client also checks one transfer contains
both that recipient and amount. This fixture was independently checked by public
Ethereum RPC on 2026-09-06 (chain ID 1, canonical USDT Transfer, 100000 raw units).

## Schemas: implemented interface and intended roadmap

These four inputSchema objects exactly match the pinned server; no extra required
fields, patterns or additionalProperties rules are implied.

```json
{
  "wallet.address":{"type":"object","properties":{}},
  "wallet.balance":{"type":"object","properties":{"address":{"type":"string"}}},
  "wallet.verify_tx":{"type":"object","properties":{"tx":{"type":"string"},"expected_to":{"type":"string"},"expected_usdt":{"type":"number"}},"required":["tx"]},
  "wallet.policy":{"type":"object","properties":{}}
}
```

The original six-tool roadmap names address, balance, verify_tx, send, swap_quote
and swap. The current server additionally exposes policy and does not expose the
last three roadmap tools. The union therefore has seven names: this section covers
all six intended tools plus the current policy tool, without changing tools/list.

The following are illustrative input schemas for future design discussion only.
They are not advertised by the pinned server, not its accepted call contract, and
not implemented here. **wallet.send and wallet.swap remain NOT EXPOSED until
THREAT-MODEL.md C2, as declared by the pinned server.** A schema is not permission
to implement or execute them; no assertion that C2 is satisfied is made here.

```json
{
  "wallet.send":{"type":"object","properties":{"to":{"type":"string"},"amount_usdt":{"type":"string"},"purpose":{"type":"string"}},"required":["to","amount_usdt","purpose"]},
  "wallet.swap_quote":{"type":"object","properties":{"amount_usdt":{"type":"string"},"fee":{"type":"integer"},"slippage_bps":{"type":"integer"}},"required":["amount_usdt"]},
  "wallet.swap":{"type":"object","properties":{"quote_id":{"type":"string"},"min_amount_out_wei":{"type":"string"},"deadline":{"type":"integer"}},"required":["quote_id","min_amount_out_wei","deadline"]}
}
```

The draft quote shape assumes the current USDT-to-WETH direction. Decimal amounts
and wei use strings in draft schemas to preserve precision. Future API owners must
settle validation, quote identity and execution semantics before exposing them.
These examples do not claim a quote_id API currently exists.

## Recorded checks and limits

On macOS, Python 3.10 and Node 23.9, the pinned server passed offline (3 checks,
4 messages) and online (5 checks, 6 messages). selftest.py separately uses an
authored fixture server: baseline passes; adding send, adding swap or changing an
input schema each fails. It tests the client, not wallet enforcement. No real
signer or wallet operation was run. This check is tied to a commit, not future code.

Primary protocol references, pinned to MCP 2024-11-05:
[stdio](https://modelcontextprotocol.io/specification/2024-11-05/basic/transports),
[lifecycle](https://modelcontextprotocol.io/specification/2024-11-05/basic/lifecycle),
[tools](https://modelcontextprotocol.io/specification/2024-11-05/server/tools), and
[JSON-RPC 2.0](https://www.jsonrpc.org/specification).
