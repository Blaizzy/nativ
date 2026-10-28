# Why recall improved, latency increased, and live research still failed

Historical investigation on 27 October 2026, against source `bca5f492`.
The subsequent fix in Nativ `e70aaf70` and MLX-VLM `40f0a1e8` addresses these
integration failures; see the new validation in [RESULTS.md](RESULTS.md).
The evidence below records the pre-fix behavior. It audits the recorded
comparison and runs 21 controlled, saved-request replays on the same M3 Ultra,
checkpoint and runtime described in [RESULTS.md](RESULTS.md). Returned browser
actions in the replays were inspected, not executed.

## 1. The prototype's transient evidence is carried inside server capsules

`ChatBrowserEvidence` reconstructs a bounded record from original tool receipts.
This gives the model the early checkpoint tokens again after a lossy summary,
explaining the improved exact recall. However, the storage contract is wrong:

1. `MLXChatCompletionRequest.contextMessages` turns the evidence into an ordinary
   `user` message. `NativResponsesClient` appends it after the canonical history.
2. Nativ excludes it from its client-side saved transcript prefix, but the server
   receives no indication that this message is transient.
3. MLX-VLM compacts normal input messages and seals the retained evidence into its
   returned capsule. On replay, `resolve_context` restores that evidence.
4. Nativ appends the fresh evidence again. The server merges the restored history
   and the new tail without replacing old environment snapshots.

Inspecting the actual capsules confirmed two evidence blocks after compaction in
`chain-8192-recovery-0`. In `live-8192-recovery-1`, steps 11–25 contained **three
blocks totaling 8,454 bytes**, although the current block was only **3,441 bytes**.
There were two identical copies of the current block plus one stale block. The
original user request was still present; it had not simply disappeared.

This makes the promised byte bound apply to each fresh block rather than the
whole restored prompt. The server also treats environment snapshots as user
turns when choosing what to protect or retain during compaction.

For a causal check, the replay removes only earlier evidence messages from the
saved capsule and preserves the current evidence, original task, handoff and new
tail. On the selected live request, pre-compaction input falls from **6,375 to
4,791 tokens**, below the **6,144-token** trigger. Compaction occurs in all three
original replays and none of the three replays with the carried copies removed.

With output limited to one token in both arms, median request time is **3.986 s
versus 1.166 s**, across three trials each. Both arms have zero cached prompt
tokens in this control. This isolates a real compaction/prompt-processing cost;
it is not an end-to-end research speedup.

Without that output control, removing the copies changes the generated action
and increases output from 260 to 590 tokens: median total time is **6.607 s versus
7.295 s**. It stops the repeated search on this request but generates a shortened
URL instead. Removing duplication alone is not a complete fix.

## 2. Extra evidence also reduces prefix-cache reuse

The evidence block changes at the end of each request. That tail becomes a
different sequence on the next request, and compaction replaces more of the
history. The cache was enabled, but its measured reuse decreased:

| 24-page chain, three trials per arm | Baseline | Revised |
| --- | ---: | ---: |
| Compactions per run | 3 | 6 |
| Mean cached fraction of reported input tokens | 77.7% | 37.1% |
| Mean uncached input tokens across the task | 22,206 | 71,355 |
| Requests reporting zero cached tokens per run | 4 | 12 |
| Mean time executing browser tools | 3.21 s | 3.19 s |

The slowdown is predominantly additional inference work, not slower fixture page
loads. Token counts exclude internal summary generations, so they understate the
total work. Cache statistics establish the loss of reuse; they do not isolate
every cache eviction or hybrid-state checkpoint decision.

## 3. The model opens shortened display URLs instead of following result links

The three revised live runs made **50 searches and 39 opens, with zero clicks**.
Google snapshots supplied element IDs and actual anchor hrefs, often opaque
Google redirect URLs. The model frequently reconstructed an address from the
shortened display path. For example, it opened
`https://www.f22labs.com/blogs/ocr-models-compari`, which returned 404, rather
than clicking the supplied result. It also opened bare site homepages where the
search result referred to a particular article.

On the captured first search response, three original replays all chose the same
shortened address. Adding an explicit instruction to click result IDs still
produced an `open` with a reconstructed address in all three trials (it expanded
the path to `ocr-models-comparison`). Removing opaque hrefs while retaining IDs
and labels also produced the original shortened address in all three trials.
Neither change made the model follow the advertised result ID in this saved
request. No candidate addresses were opened in these replays, and they do not
evaluate a redesigned result representation or full research completion.

The current guidance demonstrates `open` for source pages and only generically
says to use element IDs. That is a plausible contributor, but the replays do not
isolate its effect from the model's action-selection behavior.

## 4. Observed page count is not validated research progress

The evidence filter checks HTTP/tool success, URL patterns, a small exact-title
denylist and nonempty text. It does not establish that a source is readable and
relevant. Actual captures show:

- A Medium response titled `Medium` whose body says `PAGE NOT FOUND / 404` enters
  the ledger because it does not match the exact error-title filter.
- A Facebook login/consent screen is counted as a visited source.
- General cloud-compute and blog-directory homepages contribute to the count.
- Conversely, a Reddit page containing a real discussion is omitted because its
  URL still has `js_challenge=1` after the challenge has cleared.

The ledger warns that a visited page may not be useful, but the model still treats
the count as proof that it completed the requested reads. The benchmark's manual
review catches this; the app has no equivalent check on research fulfillment.

## 5. The loop ends on any ordinary answer

`ChatViewModel` returns when the model emits no tool calls. It does not check
whether the requested research is complete. The two fresh follow-up runs ended
after 16 and 8 tool calls: one falsely declared success, and the other asked
whether it should continue despite acknowledging the missing sources.

The closing instruction applies only at round 32, so it cannot prevent either
early exit. It improves the two saved final-request replays but does not control
premature stopping. In the earlier live run, 15 consecutive searches added no
new page reads, yet there was also no check for lack of progress.

## Fixes indicated by the evidence

First, give transient environment data explicit semantics across the client and
runtime: include it in prompt budgeting and generation, while excluding carried
copies from saved compaction state. Merely excluding it from the client transcript
is insufficient. Verify the contract with several compaction/replay cycles.

Next, make following a search result an unambiguous operation within the existing
Chat Work browser, validate actual readable source content separately from visits,
and track incomplete/no-progress research before accepting a final answer. Keep
the tool-round cap as a resource limit. These were proposals at diagnosis time. The subsequent implementation and its
measured limits are recorded in RESULTS.md; this historical investigation alone
did not establish their effectiveness.

Artifacts: `diagnosis/capsule-structure.json`, `diagnosis/probe-summary.json`,
per-replay requests/events, `timing-breakdown.json`, and the two diagnostic scripts
are retained alongside the benchmark captures. To reproduce, use the original
artifact layout and runtime environment, run `diagnosis/inspect_capsules.py`, then
`diagnosis/probe_causes.py` and `diagnosis/probe_causes.py --prefill-only`. Capsule
inspection/replay requires the original runtime's existing key; no key is exported.
The probes use isolated port 18987, unload/warmup before each trial and reversed
arm order in the middle repetition. They do not establish general model quality,
five-source completion or a release-ready performance improvement.
