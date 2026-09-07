#!/usr/bin/env python3
"""Print recorded model traces.

NativTrace stores an append-only log of JSON events, so a trace is readable
without the app. This is the command-line view of the same data the chat panel
renders: what each model was shown, and what it did.

    scripts/dump_trace.py                 # list traces
    scripts/dump_trace.py --trace <id>    # full transcript of one trace
    scripts/dump_trace.py --latest        # full transcript of the newest trace
"""

import argparse
import json
import os
import sqlite3
import zlib
from datetime import datetime

DEFAULT_DB = os.path.expanduser("~/Library/Application Support/Nativ/Traces.sqlite3")


def payload(blob, encoding, byte_count):
    if encoding == "json":
        return json.loads(blob)
    if encoding == "json+deflate":
        # Apple's COMPRESSION_ZLIB is raw DEFLATE, so no zlib header.
        return json.loads(zlib.decompress(blob, -15, max(byte_count, 1)))
    return {"_unreadable": f"unknown payload encoding {encoding!r}"}


def clock(seconds):
    return datetime.fromtimestamp(seconds).strftime("%H:%M:%S")


def list_traces(connection):
    rows = connection.execute(
        """
        SELECT i.trace_id, i.session_id, i.event_count,
               i.started_at, i.last_event_at,
               (SELECT group_concat(model_id) FROM trace_models m
                 WHERE m.trace_id = i.trace_id)
        FROM trace_index i ORDER BY i.started_at ASC
        """
    ).fetchall()
    if not rows:
        print("no traces recorded yet")
        return
    print(f"{len(rows)} trace(s):\n")
    for trace_id, session, count, started, last, models in rows:
        print(f"  {trace_id}")
        print(f"    model    {models or 'unknown'}")
        print(f"    chat     {session}")
        print(f"    {count} events, {clock(started)} → {clock(last)}\n")


def dump(connection, trace_id):
    rows = connection.execute(
        """
        SELECT seq, ts, kind, round_index, model_id, payload, payload_encoding, payload_bytes
        FROM trace_events WHERE trace_id = ? ORDER BY seq
        """,
        (trace_id,),
    ).fetchall()
    if not rows:
        print(f"no events for {trace_id}")
        return

    print(f"trace {trace_id}\n")
    for seq, ts, kind, round_index, model, blob, encoding, byte_count in rows:
        body = payload(blob, encoding, byte_count)
        where = f" round {round_index}" if round_index is not None else ""
        print(f"[{seq:>3}] {clock(ts)}  {kind}{where}")

        if kind == "turn_started":
            print(f"        user: {body.get('text', '')}")
        elif kind == "request_composed":
            sections = body.get("systemSections", [])
            tools = body.get("tools", [])
            print(f"        system prompt: {len(sections)} section(s)")
            for section in sections:
                head = section.get("body", "").replace("\n", " ")[:70]
                print(f"          - [{section.get('origin')}] {section.get('label')}: {head}…")
            print(f"        tools offered: {len(tools)}"
                  f"{'' if body.get('advertisesTools', True) else ' (withheld this round)'}")
            for tool in tools:
                origin = tool.get("origin")
                detail = f"/{tool['originDetail']}" if tool.get("originDetail") else ""
                print(f"          - {tool.get('name')}  [{origin}{detail}]")
            print(f"        messages sent: {len(body.get('messages', []))}")
            params = {k: v for k, v in (body.get("parameters") or {}).items() if v is not None}
            if params:
                print(f"        sampling: {params}")
            for omission in body.get("omissions", []):
                print(f"        omitted: {omission.get('subject')} ({omission.get('reason')})")
        elif kind in ("response_completed", "response_delta"):
            if body.get("reasoning"):
                print(f"        thinking: {body['reasoning'][:200]}")
            print(f"        assistant: {body.get('content', '')[:400]}")
            if body.get("usage"):
                print(f"        usage: {body['usage']}")
        elif kind == "tool_call":
            print(f"        {body.get('name')}({json.dumps(body.get('arguments'))})")
        elif kind == "tool_result":
            marker = "error" if body.get("isError") else "ok"
            print(f"        {marker}: {str(body.get('output'))[:300]}")
        elif kind == "tool_consent":
            print(f"        {body.get('name')}: {body.get('decision')}")
        elif kind == "model_switched":
            print(f"        {body.get('from')} → {body.get('to')}")
        elif kind == "response_failed":
            print(f"        {body.get('message')}")
        elif kind in ("session_started", "turn_ended"):
            print(f"        {json.dumps(body)}")
        else:
            print(f"        {json.dumps(body)[:300]}")
        print()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--trace")
    parser.add_argument("--latest", action="store_true")
    args = parser.parse_args()

    if not os.path.exists(args.db):
        raise SystemExit(f"no trace store at {args.db}")

    connection = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    if args.latest:
        row = connection.execute(
            "SELECT trace_id FROM trace_index ORDER BY last_event_at DESC LIMIT 1"
        ).fetchone()
        if not row:
            raise SystemExit("no traces recorded yet")
        dump(connection, row[0])
    elif args.trace:
        dump(connection, args.trace)
    else:
        list_traces(connection)


if __name__ == "__main__":
    main()
