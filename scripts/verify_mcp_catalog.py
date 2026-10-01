#!/usr/bin/env python3
"""Launch every server in the MCP catalog and confirm it speaks MCP.

For each entry the script starts ``command`` + ``args`` over stdio, performs an
MCP ``initialize`` handshake and ``tools/list``, and treats the server as
working when it returns at least one tool. Servers that declare ``requiresFolder``
receive a temporary directory; servers that declare ``requiredEnv`` or
``verificationEnv`` receive placeholder values (a healthy server still lists
its tools without valid credentials). Commands prefixed with ``@bundled/`` are
resolved from the directory supplied with ``--bundled-directory``. An entry may
set ``"ciSkip": true`` to opt out of the live check.
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
DEFAULT_CATALOG = REPO_ROOT / "Sources" / "Nativ" / "Resources" / "MCPCatalog.json"
TIMEOUT_SECONDS = 120
BUNDLED_PREFIX = "@bundled/"


def _resolve_command(entry, bundled_directory):
    command = entry["command"]
    if not command.startswith(BUNDLED_PREFIX):
        return command

    name = command.removeprefix(BUNDLED_PREFIX)
    if not name or Path(name).name != name:
        raise ValueError(f"invalid bundled command marker: {command}")
    if bundled_directory is None:
        raise FileNotFoundError(
            f"{command} requires --bundled-directory for verification"
        )

    executable = bundled_directory / name
    if not executable.is_file():
        raise FileNotFoundError(f"bundled executable not found: {executable}")
    if not os.access(executable, os.X_OK):
        raise PermissionError(f"bundled executable is not executable: {executable}")
    return str(executable)


async def _handshake(entry, folder, bundled_directory):
    args = list(entry.get("args", []))
    if entry.get("requiresFolder"):
        args.append(folder)

    env = os.environ.copy()
    for key in entry.get("excludedEnv", []):
        env.pop(key, None)
    for key in entry.get("requiredEnv", []) + entry.get("verificationEnv", []):
        env.setdefault(key, "ci-placeholder-value")

    command = _resolve_command(entry, bundled_directory)
    params = StdioServerParameters(command=command, args=args, env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            return len(result.tools)


async def _verify(entry, folder, bundled_directory):
    try:
        count = await asyncio.wait_for(
            _handshake(entry, folder, bundled_directory), TIMEOUT_SECONDS
        )
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
    parser.add_argument(
        "--bundled-directory",
        type=Path,
        help="Directory containing executables referenced by @bundled/ commands",
    )
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
            ok, detail = await _verify(entry, folder, args.bundled_directory)
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
