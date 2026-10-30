#!/usr/bin/env python3
"""Summarize captured runs; all latency aggregates retain failures explicitly."""
import argparse
import collections
import html
import json
from pathlib import Path
import statistics
from urllib.parse import urlsplit

try:
    from .benchmark import grade
except ImportError:
    from benchmark import grade


def metrics(path):
    data = json.loads(path.read_text())
    if "grade" not in data:
        if "error" not in data:
            return None
        data["grade"] = {"completed": False, "infrastructure_error": data["error"]}
        data.setdefault("final", "")
        data.setdefault("task_seconds", 0)
    case = data["config"]["case"]
    if case == "live" and "error" not in data:
        data["grade"] = grade("live", data["final"], data["read_urls"], [])
        # A page count cannot establish that the research was completed. Preserve
        # that automatic gate separately and require a recorded source audit.
        data["grade"]["automatic_gate_passed"] = data["grade"]["completed"]
        review_path = path.with_name("review.json")
        review = json.loads(review_path.read_text()) if review_path.exists() else None
        data["grade"]["manual_review"] = review
        data["grade"]["completed"] = bool(data["grade"]["completed"] and review and review.get("completed"))
    if case in ("chain", "catalog"):
        expected_paths = ({f"/checkpoint/{i}" for i in range(1, 25)} if case == "chain" else
                          {f"/Scanner-{i:02d}" for i in range(1, 13)})
        read_paths = {urlsplit(url).path for url in data["read_urls"]}
        data["grade"]["required_pages_read"] = len(expected_paths & read_paths)
        data["grade"]["completed"] = data["grade"]["completed"] and expected_paths.issubset(read_paths)
    config = data["config"]
    steps = data["steps"]
    tools = [t for s in steps for t in s["tools"]]
    prompts = [s["inference"]["usage"].get("prompt_tokens", 0) for s in steps]
    ttft = [s["inference"]["ttft"] for s in steps if s["inference"]["ttft"] is not None]
    row = {"final_finish_reason": steps[-1]["inference"].get("finish_reason") if steps else None, "name": path.parent.name, "case": config["case"], "context": config["context"],
           "max_output_tokens": config.get("max_output_tokens", data.get("sampling", {}).get("max_tokens")),
           "mode": config["mode"], "completed": data["grade"]["completed"],
           "seconds": data["task_seconds"], "pages_read": len(set(data["read_urls"])),
           "rounds": len(steps), "tool_calls": len(tools),
           "tool_errors": sum(isinstance(t["result"], dict) and (t["result"].get("ok") is False or bool(t["result"].get("error"))) for t in tools),
           "tool_result_bytes": sum(t["result_bytes"] for t in tools),
           "prompt_tokens_sum": sum(prompts), "prompt_tokens_peak": max(prompts, default=0),
           "first_prompt_tokens": prompts[0] if prompts else 0,
           "ttft_median": statistics.median(ttft) if ttft else None,
           "prompt_drops": sum(b < a for a, b in zip(prompts, prompts[1:])),
           "compactions": sum(any(e.get("type") in ("response.completed", "response.incomplete") and any(i.get("type") == "compaction" for i in e.get("response", {}).get("output", [])) for e in s["inference"]["events"]) for s in steps),
           "grade": data["grade"], "final": data["final"]}
    if config["case"] == "chain":
        expected = {f"K{(i * 7919 + 3251) % 99991:05d}" for i in range(1, 25)}
        try:
            final = data["final"]
            answer = json.loads(final[final.index("{"):final.rindex("}")+1])
            tokens = answer.get("tokens", [])
            row["known_tokens_recalled"] = len({t for t in tokens if isinstance(t, str)} & expected)
            row["invented_tokens"] = len({t for t in tokens if isinstance(t, str)} - expected)
        except (ValueError, json.JSONDecodeError):
            row["known_tokens_recalled"] = 0
    return row


def main():
    p = argparse.ArgumentParser()
    p.add_argument("results", type=Path)
    a = p.parse_args()
    rows = [row for path in sorted(a.results.glob("*/result.json")) if (row := metrics(path))]
    groups = collections.defaultdict(list)
    for row in rows:
        groups[(row["case"], row["context"], row["mode"])].append(row)
    aggregates = []
    for (case, context, mode), values in sorted(groups.items()):
        aggregates.append({"case": case, "context": context, "mode": mode, "runs": len(values),
                           "completed": sum(r["completed"] for r in values),
                           "output_limit_finishes": sum(r["final_finish_reason"] == "length" for r in values),
                           **{key: statistics.median(r[key] for r in values if r[key] is not None) if any(r[key] is not None for r in values) else 0 for key in [
                               "seconds", "pages_read", "tool_calls", "tool_errors", "tool_result_bytes",
                               "prompt_tokens_sum", "prompt_tokens_peak", "first_prompt_tokens", "ttft_median"]},
                           "seconds_range": [min(r["seconds"] for r in values), max(r["seconds"] for r in values)],
                           "known_tokens_recalled": [r.get("known_tokens_recalled") for r in values],
                           "correct_catalog_records": [r["grade"].get("correct_records") for r in values]})
    (a.results / "summary.json").write_text(json.dumps({"groups": aggregates, "runs": rows}, indent=2))
    table = "".join(f'<tr><td>{r["case"]}</td><td>{r["context"]:,}</td><td>{r["mode"]}</td>'
                    f'<td>{r["completed"]}/{r["runs"]}</td><td>{r["output_limit_finishes"]}</td><td>{r["seconds"]:.1f}</td>'
                    f'<td>{r["pages_read"]:g}</td><td>{r["prompt_tokens_sum"]:,.0f}</td>'
                    f'<td>{r["tool_result_bytes"]/1024:.1f}</td></tr>' for r in aggregates)
    details = "".join(f'<details><summary>{html.escape(r["name"])} — {"PASS" if r["completed"] else "FAIL"}, '
                      f'{r["seconds"]:.1f}s, {r["pages_read"]} pages</summary>'
                      f'<pre>{html.escape(json.dumps({k:v for k,v in r.items() if k != "final"}, indent=2))}</pre>'
                      f'<pre>{html.escape(r["final"])}</pre></details>' for r in rows)
    counts = sorted({r["runs"] for r in aggregates})
    budgets = sorted({r["max_output_tokens"] for r in rows if r["max_output_tokens"] is not None})
    protocol = (f'{len(rows)} runs; {"/".join(map(str, counts))} trial(s) per condition; '
                f'{"/".join(f"{n:,}" for n in budgets)} output-token limit. '
                'Temperature 0, thinking off, memory prefix cache on, disk cache off. Model warmup is excluded.')
    comparison = (
        "Baseline and revised Chat Work, using the same WebKit engine."
        if {r["mode"] for r in rows} == {"baseline", "recovery"}
        else "Validation of one Chat Work implementation; this is not a paired speed comparison."
    )
    document = '''<!doctype html><html lang="en"><meta charset="utf-8"><title>Chat Work: long-horizon browser experiment</title>
<style>body{font:16px/1.55 system-ui,sans-serif;color:#172536;background:#f3f6f9;max-width:1180px;margin:45px auto;padding:0 24px}
h1{font-size:32px}table{width:100%;border-collapse:collapse;background:white}td,th{padding:12px;text-align:left;border-bottom:1px solid #dce4ec}
th{background:#163c57;color:white}details{background:white;padding:14px;margin:12px 0;border-radius:8px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}.note{background:#fff3cf;padding:18px;border-radius:8px}</style>
<h1>Chat Work research recovery</h1><p>Nemotron Bolt E4B 4-bit · Apple M3 Ultra, 512 GB · MLX-VLM recovery branch</p>
<p>''' + comparison + '''</p><p>''' + protocol + '''</p>
<p class="note">A faster failed task is not a speed improvement. Completion requires all requested facts and source visits for fixtures.
Live completion requires a recorded manual source review in addition to five distinct non-search page payloads and a final answer. The provisional automatic gate is retained in each run's details.</p>
<table><thead><tr><th>Task</th><th>Context</th><th>Interface</th><th>Completed</th><th>Output cap hits</th><th>Median seconds</th><th>Median pages</th><th>Reported prompt tokens, sum</th><th>Tool output KiB</th></tr></thead><tbody>''' + table + '''</tbody></table>
<p>Chain: 24 dependent pages, ordered tokens, unknown passport check. Catalog: 12 linked specifications and a constrained recommendation.
Live: the original five-page OCR research prompt. Fixture pages are synthetic and have deterministic ground truth.</p>
<p>Reported prompt tokens exclude internal compaction-summary generations. Prompt drops indicate context reduction but are not an exact compaction counter.
This uses Responses compaction-item replay and fresh transient context, matching Nativ request construction. It measures browser-tool loops, not Nativ UI timing or the original reporter's M4 machine. Preliminary debugging runs are excluded.</p>
<h2>Captured runs and answers</h2>''' + details + '</html>'
    (a.results / "report.html").write_text(document)
    print(json.dumps(aggregates, indent=2))


if __name__ == "__main__":
    main()
