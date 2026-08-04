#!/usr/bin/env python3
import json
import sys
import time

die_on_call = "--die-on-call" in sys.argv
malformed_tools_list = "--malformed-tools-list" in sys.argv
empty_tools = "--empty-tools" in sys.argv
split_write_tools_call = "--split-write-tools-call" in sys.argv


def write(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for raw_line in sys.stdin:
    line = raw_line.strip()
    if not line:
        continue
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")

    if method == "initialize":
        write({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "fake-mcp-server", "version": "1.0"}
            }
        })
    elif method == "notifications/initialized":
        continue
    elif method == "tools/list":
        if malformed_tools_list:
            write({"jsonrpc": "2.0", "id": request_id, "result": {"nope": True}})
        elif empty_tools:
            write({"jsonrpc": "2.0", "id": request_id, "result": {"tools": []}})
        else:
            write({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tools": [{
                        "name": "echo",
                        "description": "Echoes back its input argument.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"text": {"type": "string"}}
                        }
                    }]
                }
            })
    elif method == "tools/call":
        if die_on_call:
            sys.exit(0)
        arguments = request.get("params", {}).get("arguments", {})
        text = arguments.get("text", "")
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "content": [{"type": "text", "text": f"echo:{text}"}],
                "isError": False
            }
        })
        if split_write_tools_call:
            midpoint = len(payload) // 2
            sys.stdout.write(payload[:midpoint])
            sys.stdout.flush()
            time.sleep(0.05)
            sys.stdout.write(payload[midpoint:] + "\n")
            sys.stdout.flush()
        else:
            sys.stdout.write(payload + "\n")
            sys.stdout.flush()
