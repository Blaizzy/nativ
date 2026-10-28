# Existing Chat Work research recovery

This experiment keeps the `chat_work` tool and shared WebKit browser. It adds a
bounded, transient record of exact source excerpts for the current user request,
plus structured Google result actions, readable-page checks, direct navigation for URL
search queries, and an explicit final-answer instruction at the tool-round limit.
The closing instruction follows the evidence and is also present in the system
guidance. Current clients send environment data in `transient_context`, requiring
MLX-VLM PR #2612 before release. PR #2613 also fixes reasoning/tool parsing in long loops. It is counted and rendered but never sealed into a
capsule. Older client capsules rebuild once from the canonical transcript. There
are no compact browser tools and no installed CLI entry point.

Search result titles already opened in a tab are deprioritized, not hidden. The
`open` + `element_id` form resolves a captured HTTP(S) search link across page visits;
other elements use click validation and consent. DOM actions keep stale-reference checks.
Page reads prioritize text over menus; consent/error screens, short member previews and
media metadata without a rendered transcript do not count as readable evidence.
For explicit English numeric page-read requirements, the app permits two early-final
continuations within the existing round cap. These checks do not establish source
relevance; the live benchmark still requires manual review.

See [measured results and limitations](RESULTS.md).

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
  item plus the new conversation tail; send exact excerpts keyed by tool-call ID in
  `tool_result_context`. The server renders only excerpts whose receipts have
  left context, before the retained history. Mutable environment state remains
  in `transient_context`, after history. Neither is saved in compaction items.
- Primary 8K comparison: three trials per condition, reversing the order in the
  middle repetition. Exploratory 16K checks: one trial per condition. Baseline
  and revised arms both expose only `chat_work`.
- Both arms allow 4,096 output tokens to reduce the output-limit confound found in
  the earlier experiment. Both allow 32 tool rounds followed by one generation
  without tools, matching the app's round gate. The revised arm receives closing
  guidance; the baseline retains its existing behavior. A 30-minute task deadline
  applies. The recorded 22-run comparison predates the final change that repeats
  closing guidance after evidence; separate replays and fresh live runs evaluate
  that change. Pin the source revision listed in RESULTS.md to reproduce each stage.
- A 24-page dependent chain checks exact ordered recall and an unknown fact.
  A 12-page catalog checks every record, a total and a constrained recommendation.
  Facts occur only in served pages, never in the model prompt or evidence code.
- The original five-page live OCR request runs at 8K. Search snippets and repeated
  reads cannot satisfy its source count. The automatic live gate requires five
  distinct page payloads plus a final answer. `summarize.py` also requires a
  `review.json` beside each live `result.json`, containing `completed` and the
  review rationale. Without a recorded review, live completion is false; the
  provisional automatic gate remains visible separately.
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

For the final comparison, run three repetitions of all tasks at 8K (`--contexts
8192 --repetitions 3`), then a separate exploratory 16K run (`--contexts 16384
--cases chain catalog --repetitions 1`). Do not pool the single 16K trials with the
repeated 8K conditions. Earlier pilot and diagnostic captures remain excluded.

## Fix validation

The latest measured implementation is Nativ `6d400d53` with runtime `40f0a1e8` (PRs #2612 and #2613). Run the
revised arm alone with `--modes recovery`, keeping new output in a separate directory.
The historical v2/v3 comparison used the earlier message-based context protocol;
its source snapshots are retained with its artifacts. Do not rerun current code
and label it as that historical baseline, or pool the intermediate v4/v5 pilots
with final measurements. The completed intermediate v9/v10 batches are retained separately:
they exposed the reasoning/tool streaming error, linked-index counting and additional
source-quality issues. Final v12 runs are stored separately. Source receipts, model answers, infrastructure failures
and manual reviews must remain visible even when a run fails.
