# Existing Chat Work research recovery

This experiment keeps the `chat_work` tool and shared WebKit browser. It adds a
bounded, transient record of exact source excerpts for the current user request,
plus source-first Google controls and absolute link URLs. There are no compact
browser tools and no installed CLI entry point.

`build_helper.py` temporarily appends the test bridge to `Main.swift`, builds,
then restores every modified source in `finally`. Do not edit or run another build
in that checkout concurrently. It requires a complete existing Debug server
resource under `build/ReportDerivedData`. The copied helper excludes that resource
because it only executes browser actions. To build both arms:

```sh
python3 scripts/benchmarks/chat_work_recovery/build_helper.py --baseline-ref 409d910a --output /path/to/baseline
python3 scripts/benchmarks/chat_work_recovery/build_helper.py --output /path/to/recovery
```

Run `run_suite.py` on one Apple Silicon host using a Python environment containing
the tested MLX-VLM runtime, with `--baseline-binary`, `--recovery-binary`, `--model`
and `--output`. The runner serializes model workloads. The bridge exposes only
existing browser actions, the actual `chat_work` schema/session guidance and the
production evidence builder. Cookies are isolated in a nonpersistent profile.

## Protocol

- Same checkpoint, hardware, temperature zero, thinking disabled, memory prefix
  cache enabled, disk cache disabled. Unload and an excluded warmup per trial.
- `/v1/responses` with a 75% compaction threshold. Replay the returned compaction
  item plus the new conversation tail; append fresh evidence outside the saved
  prefix, following Nativ's client request construction.
- 8K and 16K contexts; three trials per condition, reversing the order in the
  middle repetition. Baseline and revised arms both expose only `chat_work`.
- Both arms allow 4,096 output tokens to reduce the output-limit confound found in
  the earlier experiment. Both allow 32 tool rounds followed by one generation
  without tools, matching the app's round gate. A 30-minute task deadline applies.
- A 24-page dependent chain checks exact ordered recall and an unknown fact.
  A 12-page catalog checks every record, a total and a constrained recommendation.
  Facts occur only in served pages, never in the model prompt or evidence code.
- The original five-page live OCR request runs at 8K. Search snippets and repeated
  reads cannot satisfy its source count. The automatic live gate requires five
  distinct page payloads plus a final answer; manually inspect source quality.
- Raw captures include exact schemas, prompts, tool calls/results, evidence
  context, Responses events, compaction items, timing, usage and runtime health.

These results must not be pooled with the previous Chat Completions experiment:
route, output allowance and round limit changed for **both** arms. This is a
browser-tool evaluation, not a complete UI latency measurement; other app tools,
work-pane item listings, attachments and user consent interactions are excluded.
Live results vary. Excerpts cover the beginning of each captured page and are
incomplete; retaining them does not guarantee that every fact on a page survives.

Use `summarize.py /path/to/results` for an HTML report and JSON summary. Keep pilot
runs separate from measured trials. A shorter failed run is not a speedup.
