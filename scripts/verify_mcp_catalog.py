#!/usr/bin/env python3
"""Launch every server in the Tools catalog and confirm it speaks MCP.

For each entry the script starts ``command`` + ``args`` over stdio, performs an
MCP ``initialize`` handshake and ``tools/list``, and treats the server as
working when it returns at least one tool. Servers that declare ``requiresFolder``
receive a temporary directory; servers that declare ``requiredEnv`` receive
placeholder values (a healthy server still lists its tools without valid
credentials). An entry may set ``"ciSkip": true`` to opt out of the live check.
"""

import argparse
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
except ImportError:
    print("The 'mcp' package is required: pip install mcp", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = REPO_ROOT / "Sources" / "Nativ" / "Resources" / "ToolCatalog.json"
TIMEOUT_SECONDS = 120


async def _handshake(entry, folder):
    args = list(entry.get("args", []))
    if entry.get("requiresFolder"):
        args.append(folder)

    env = os.environ.copy()
    for key in entry.get("requiredEnv", []):
        env.setdefault(key, "ci-placeholder-value")

    params = StdioServerParameters(command=entry["command"], args=args, env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            return len(result.tools)


async def _verify(entry, folder):
    try:
        count = await asyncio.wait_for(_handshake(entry, folder), TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        return False, f"timed out after {TIMEOUT_SECONDS}s"
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"
    if count == 0:
        return False, "connected but exposed no tools"
    return True, f"{count} tool(s)"


def _write_summary(rows):
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    lines = ["| Server | Result | Detail |", "|---|---|---|"]
    lines += [f"| {name} | {status} | {detail} |" for name, status, detail in rows]
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--only", help="Verify a single entry by id")
    args = parser.parse_args()

    entries = json.loads(args.catalog.read_text(encoding="utf-8"))
    if args.only:
        entries = [entry for entry in entries if entry.get("id") == args.only]

    rows = []
    failures = 0
    with tempfile.TemporaryDirectory() as folder:
        for entry in entries:
            name = entry.get("name", entry.get("id", "?"))
            if entry.get("ciSkip"):
                reason = entry.get("ciSkipReason", "opted out via ciSkip")
                rows.append((name, "skipped", reason))
                print(f"[skip] {name}: {reason}", flush=True)
                continue
            ok, detail = await _verify(entry, folder)
            rows.append((name, "pass" if ok else "FAIL", detail))
            if not ok:
                failures += 1
            print(f"[{'ok' if ok else 'FAIL'}] {name}: {detail}", flush=True)

    _write_summary(rows)

    if failures:
        print(f"\n{failures} server(s) failed verification.", file=sys.stderr)
        sys.exit(1)
    print("\nAll servers verified.")


if __name__ == "__main__":
    asyncio.run(main())
