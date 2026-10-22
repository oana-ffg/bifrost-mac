#!/usr/bin/env python3
"""Protocol checks that do not request permissions or read personal data."""
import json
import subprocess
import sys

binary = sys.argv[1]
messages = [
    {"jsonrpc": "2.0", "id": 0, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "bifrost_events", "arguments": {"start": "invalid", "end": "invalid"}}},
    {"jsonrpc": "2.0", "id": 4, "method": "unsupported"},
    {"jsonrpc": "2.0", "id": 5, "method": "ping"},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "bifrost_status", "arguments": []}},
]
run = subprocess.run([binary, "mcp"], input="\n".join(json.dumps(x) for x in messages) + "\n{bad}\n", text=True, capture_output=True, timeout=15, check=True)
rows = [json.loads(line) for line in run.stdout.splitlines()]
by_id = {row["id"]: row for row in rows}
assert by_id[0]["error"]["code"] == -32002
assert by_id[1]["result"]["protocolVersion"] == "2025-11-25"
assert len(by_id[2]["result"]["tools"]) == 4
assert by_id[3]["result"]["isError"] is True
assert by_id[4]["error"]["code"] == -32601
assert by_id[5]["result"] == {}
assert by_id[6]["error"]["code"] == -32602
assert by_id[None]["error"]["code"] == -32700
assert len(rows) == 8
assert not run.stderr, run.stderr
print("MCP lifecycle, errors, schemas and stdout purity passed")
