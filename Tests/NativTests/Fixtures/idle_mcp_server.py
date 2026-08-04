#!/usr/bin/env python3
"""A minimal MCP server that completes the handshake and then just sits there.

Exists so a test can connect a real MCPClient to a real child process and
then kill it. It answers `initialize` and `tools/list` and nothing else --
enough for the handshake to succeed, and no reason to grow further.

Writes its own pid to the path given as the first argument, so the test can
watch the actual OS process rather than trusting the client's own bookkeeping
about whether it terminated something.
"""
import json
import os
import sys

if len(sys.argv) > 1:
    with open(sys.argv[1], "w") as handle:
        handle.write(str(os.getpid()))


def write(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


# Blocking on stdin is what keeps this alive: nothing else is sent after the
# handshake, so the process stays up until it is signalled.
for raw_line in sys.stdin:
    line = raw_line.strip()
    if not line:
        continue
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue

    method = request.get("method")
    request_id = request.get("id")
    if request_id is None:
        # A notification (`notifications/initialized`); nothing to answer.
        continue

    if method == "initialize":
        # Echo the client's own protocol version back rather than pinning one,
        # so this fixture keeps working across SDK upgrades.
        requested = request.get("params", {}).get("protocolVersion", "2024-11-05")
        write({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": requested,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "idle-mcp-server", "version": "1.0"},
            },
        })
    elif method == "tools/list":
        write({"jsonrpc": "2.0", "id": request_id, "result": {"tools": []}})
    else:
        write({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "Method not found"},
        })
