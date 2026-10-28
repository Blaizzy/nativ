# Chat Work fixes — 28 October 2026

The browser remains the existing `chat_work` tool in the shared WebKit window.
The integration faults are fixed, including a separate runtime tool-parser error
found by the new long-task tests. Research answer quality remains an empirical
limit; the tables below distinguish page reads from correct answers.

## Decode-cache follow-up

MLX-VLM `650e79c5` avoids extracting and rebuilding a single-row attention cache
on every decoded token. Padded prefill retains its row-wise recovery path,
including one-token chunks after cancellation. A repetition penalty of 1.0
also stops creating a no-op processor. Chat Work prompts, source excerpts, tool
schemas and model settings are unchanged from the conditional-evidence run.

Three fresh trials with the same 27B 4-bit model, M3 Ultra, 24-page fixture,
32K context and two-entry/16 GiB memory cache:

| Metric | Conditional evidence | Decode-cache optimization |
| --- | ---: | ---: |
| Median elapsed | 127.7 s | 109.1 s |
| Range | 127.5–128.2 s | 109.0–109.4 s |
| Generated tokens per run | 1,695 | 1,695 |
| Correct ordered facts | 24/24 in 3/3 runs | 24/24 in 3/3 runs |
| Unknown value preserved | 3/3 | 3/3 |
| Peak process RSS | 15.51–15.53 GiB | 15.51–15.52 GiB |

This cuts median elapsed time by 14.6%. Input processing remains about
51 s per task; measured decode time falls from about 70 s to 52 s. Fresh browser
identifiers cause small input-token differences (18,999–19,063 uncached tokens
in the new runs); the generated token count is unchanged. No swap was used.

A frozen final-request replay, with exactly the same messages and tools, returns
the identical 288-token answer in every run. Excluding the cold request, its
three-repeat median falls from 13.96 s to 9.56 s. Both versions reuse 16,868 of
16,869 prompt tokens. This isolates generation/cache overhead from browser work.

The 8K check also recalled all 24 facts and preserved the unknown value after six
compactions: 260.9 s versus 280.8 s in the earlier run, with no API errors and
1,583 output tokens in both. This is one trial per implementation at 8K.

Runtime validation: 2,476 tests passed, eight optional tests skipped. Coverage
includes cache growth boundaries, float32/bfloat16 logits and recurrent-state
parity, padded prefill after cancellation, and active presence/frequency penalties.
The cache-owner and neutral-penalty regression checks fail on the previous runtime.
CI additionally exposed an older audio test stub that did not accept checkpoint
keyword arguments. After updating that stub, the audio file passed 65 tests and
six subtests, with two optional skips.
An early, less conservative prototype is excluded from these final timings because
it failed the added single-token padded-prefill check.

These measurements do not resolve the live-research quality failures below.
Nativ dependency requirements are unchanged.

## Evidence and cache efficiency follow-up

The client now sends exact excerpts keyed by tool-call ID in `tool_result_context`.
MLX-VLM renders only excerpts whose original receipts are absent after compaction,
in a stable block before retained conversation history. Changing browser state
stays in `transient_context`; the runtime verifies the stable token prefix and
prioritizes a checkpoint there. Current-tab navigation guidance omits the optional
browser UUID. Chat Work remains the shared browser.

Validation on M3 Ultra with the same Qwen3.8-27B 4-bit checkpoint, 24-page fixture,
32K window, thinking disabled and two-entry/16 GiB memory cache:

| Metric | Previous cache recovery | Conditional evidence and explicit boundary |
| --- | ---: | ---: |
| Elapsed | 292.1 s (one run) | 127.5–128.2 s; median 127.7 s (three runs) |
| Uncached input tokens, matching first run | 71,916 | 19,023 |
| Generated tokens, matching first run | 2,572 | 1,695 |
| Correct ordered facts | 24/24 | 24/24 in all three runs |
| Unknown value preserved | yes | yes in all three runs |

An 8K run also recalled all 24 facts and preserved the unknown value after six
compactions: 280.8 s versus 411.6 s in the saved earlier 8K run. Summary generation
still accounts for much of the smaller-window cost; the speedup does not eliminate
that work.

Live 8K OCR research completed in 353.3 s after five compactions, with no API error
and a substantive comparison. Manual review still **fails answer quality**:
project identity was not established correctly and numbers from different
benchmarks were presented as comparable rankings. The automatic page count also
includes a soft error and a link preview; manual review excludes them.
Loop completion is not proof of a correct research answer.

Native validation: 84 tests executed, one optional test skipped, no failures;
32 evidence/compaction tests rerun after removing the unused legacy formatter,
again with one optional skip and no failures. Seven harness tests passed. The
final helper build returns identical tool definitions and recovery payloads to
the measured helper. Production Nativ source: `3ff112a7`; no requirements changed.
This follow-up additionally requires MLX-VLM [#2617](https://github.com/Blaizzy/mlx-vlm/pull/2617).

## Implemented changes

- Request-local `transient_context` is budgeted and rendered by MLX-VLM without
  entering summary inputs, stored history or compaction capsules. Nativ sends it
  separately on both API routes and invalidates old client capsules once.
- Search results carry stable open actions backed by captured full URLs. They
  survive navigation away from the result page; live DOM actions retain stale
  checks and consent. Search snapshots exclude unrelated page-navigation links,
  while retaining result actions and consent controls.
- Page reads reserve more space for source text. HTTP/soft errors, login and
  consent screens, short member previews, and video metadata without a rendered
  transcript are excluded from the evidence ledger. Repeated Reddit challenge
  URLs count once.
- Explicit English page-read requirements, including linked-page requests,
  receive bounded progress guidance. Supplied index URLs do not count as their
  requested children. Up to two early-final continuations share the existing
  32-round cap. These checks do not certify source relevance or truth.
- Runtime final tool parsing now excludes reasoning, matching incremental parsing.
  A quoted old call inside reasoning can no longer replace the real next call.
  Stream/final argument consistency validation remains enabled.

Nativ requirements are unchanged. The client needs MLX-VLM
[#2612](https://github.com/Blaizzy/mlx-vlm/pull/2612) and the long-loop parser fix
[#2613](https://github.com/Blaizzy/mlx-vlm/pull/2613) before release. The client
changes are in [#780](https://github.com/Blaizzy/nativ/pull/780), stacked on #778.
No keyless search service, separate browser tool or production CLI was added.

## Causal checks

The intermediate v9 batch (`5a09f4de` / `8ee8d5a5`) retained **zero environment
snapshots in 93 replayed requests**, and all retained the original task. This
checks actual sealed capsules on their original host, not just request JSON.

One v9 chain failed at checkpoint 14. Capturing and replaying its next request
reproduced the server failure: reasoning quoted the previous element ID, whereas
the executable call used the next element ID. The final parser consumed the
quoted call and disagreed with the streamed call. The exact saved request completed
with the correct next call in **3/3 fixed replays**. The replayed calls were
inspected, not executed. The original failed run is preserved.

## Intermediate completed batches

Each row uses three trials per task at 8K. These are different implementations,
not paired speed comparisons, and are excluded from the final measurements.

| Batch | Nativ / runtime | Chain correct | Catalog correct | Live correct after review |
| --- | --- | ---: | ---: | ---: |
| v9 | `5a09f4de` / `8ee8d5a5` | 2/3 | 0/3 | 0/3 |
| v10 | `e70aaf70` / `40f0a1e8` | 3/3 | 0/3 | 1/3 |

V9 includes the streaming infrastructure failure. Its recorded task timer stops
at the last successful step, so it is not used as a completed-run latency estimate.
V10 has no API failures. Its live run failures were a misattributed model list and
an unrelated Google accessibility page counted as a fifth source. Its catalog
runs read 11/12 specifications and counted the index as page 12, prompting the
linked-read guard. All original answers and manual review rationales are retained.

## Final validation

Nine fresh runs using Nativ `6d400d53` and MLX-VLM `40f0a1e8`, three trials
per task at 8K. These are validation runs of the fixed implementation, not a
paired baseline speed comparison. Times include answer-quality failures.

| Task | Required pages read | Correct final answer | Median seconds (range) |
| --- | ---: | ---: | ---: |
| 24-page dependent chain | 3/3 | 3/3 | 65.1 (50.6–69.2) |
| 12-page catalog and calculation | 3/3 | 0/3 | 39.7 (38.6–45.3) |
| Live OCR research, five pages | 3/3 | 2/3 | 65.5 (62.4–83.0) |

- **Chain:** all 24 exact tokens in order and unknown passport preserved as null
  in every run.
- **Catalog:** all 12 specifications read, all 12 records correct, and the correct
  recommendation in every run. The totals were 2,566, 2,467 and 2,466 instead of
  2,722. The read/recall failure is fixed; arithmetic remains incorrect.
- **Live:** all three runs read five actual relevant pages. Two returned supported
  comparisons with correct source links. The third mostly listed sources/models
  and repeated progress counts instead of synthesizing a useful comparison. It is
  graded failed even though browsing completed. Public benchmark claims are only
  checked against captured sources, not independently endorsed.

There were **zero API or tool-execution errors** and **42 compactions**. An audit
of **106 capsule-replay requests found zero saved environment snapshots**, with
the original task present in all 106. The isolated benchmark servers and browser
helpers exited after the suite. No blanket end-to-end speedup or reliable
open-ended reasoning claim follows from this small sample. Answer quality is
still inconsistent.

## Protocol and limits

Apple M3 Ultra, 512 GB, macOS 27.0; not the original M4/32 GB reporter's machine.
Same Nemotron Bolt E4B 4-bit checkpoint as the historical experiment below:
revision `4274caa99dbacb12cbbca9bd9595a5063a33880f`. MLX 0.32.4, Transformers
5.21.0, Python 3.12.12. `PYTHONPATH` selects the recorded runtime source; installed
package metadata alone does not identify the executed revision.

Temperature 0, `enable_thinking:false`, 4,096 output tokens, memory prefix cache
on, disk cache off, 75% compaction, 8,192-token context. The model can still emit
reasoning despite that request flag. Every trial unloads and performs an excluded
warmup. The test bridge uses actual native browser code and production request
context with an isolated cookie profile. Other app tools and interactive consent
are excluded, so these are browser-component timings rather than full-app latency.

Source excerpts are incomplete and source quality is assessed against captured
receipts, not by independently verifying every public claim. A relevant model
directory may count as a page read; search snippets, unrelated help pages and
blocked pages do not. A successful live answer must provide a comparison grounded
in at least five actual relevant page reads without inventing a source. The one
small model and one live prompt do not establish general research reliability.

Validation: **135 focused native tests passed, one optional live test skipped**;
**839 runtime server/tool-streaming tests passed**, with 14 optional real-model
cases excluded; **73 processor/tool-parser tests passed**; **7 harness tests
passed**. Runtime formatting/import checks passed. Frozen patches, source and
binary hashes, raw requests/results/events, manual reviews and test logs are
retained in the evidence artifact. Intermediate pilots are labeled separately.

The historical comparison below is unchanged evidence from before these fixes;
its timings and implementation limitations must not be presented as current.

---

# Historical benchmark — 27 October 2026

The revised existing `chat_work` path preserves exact facts better across
compaction, at additional latency. It does **not** reliably finish open-ended
research with this model. These results support a draft for further evaluation,
not a claim that the original browsing report is fully resolved.

[Follow-up diagnosis](DIAGNOSIS.md) found that server capsules retain copies of
the supposedly transient evidence. Controlled replays confirm this causes extra
compaction. Separate navigation, source-validation and early-stopping failures
remain. The diagnosis does not change the implementation or results below.

The compact-command experiment was reverted. Chat Work remains the primary
browser, using its existing WebKit engine and Google search. No API key, new
browser tool, normal CLI entry point, or dependency requirement change is part
of this patch.

## Repeated 8K comparison

Three trials per arm and task; 18 runs total. Completion requires every requested
fixture page, correct facts, valid JSON, arithmetic and recommendation where
requested. The live task also requires manual review of actual source receipts.
Times below include failures and exclude model warmup.

| Task | Baseline complete | Revised complete | Baseline median seconds (range) | Revised median seconds (range) |
| --- | ---: | ---: | ---: | ---: |
| 24-page dependent chain | 1/3 | 3/3 | 32.9 (27.3–37.7) | 55.4 (54.9–55.8) |
| 12-page catalog and calculation | 0/3 | 0/3 | 34.7 (30.4–38.4) | 41.1 (41.0–47.0) |
| Live OCR research, five pages | 0/3 | 0/3 | 94.3 (82.5–106.6) | 194.7 (181.9–199.0) |

- **Chain:** baseline retained 24, 17 and 5 of the 24 known tokens; revised
  retained all 24 in the correct order in all three runs. Both preserved the
  unknown passport as null. Every run visited all 24 pages. The revised runs
  compacted six times each, versus three for baseline. Median reported prompt
  tokens increased from 100,168 to 113,423 across the task. This is a recall
  improvement, not a speed improvement.
- **Catalog:** two revised answers contained all 12 exactly correct records.
  Their totals were 2,386 and 2,369 rather than 2,722; one also chose Scanner-10
  instead of the required Scanner-01. The third answer had malformed JSON and
  a wrong total. Baseline produced truncated JSON, a request for missing facts,
  and invented record values. All six runs visited the 12 specifications.
- **Live:** all baseline runs and two revised runs reached the tool cap and
  returned raw tool-call markup. The remaining revised run passed the provisional
  page-count gate but failed manual review: it counted an implied fifth source,
  included a Medium 404 and an unrelated cloud-compute homepage, and asked to
  continue instead of completing the requested comparison. A loaded URL is not
  proof of a usable source. The committed summarizer now requires a recorded
  manual review before marking live research complete.

All 18 runs completed without an infrastructure/API error. All 407 tool calls
were to `chat_work`. Tool errors such as missing pages still occurred. Reported
prompt-token sums omit the runtime's internal summary-generation requests.

## Exploratory 16K checks

One trial per arm and fixture task; four runs total. These are observations,
not repeated performance estimates, and are not pooled with the 8K comparison.

| Task | Baseline | Revised |
| --- | --- | --- |
| Chain | Failed; 9/24 known tokens, 32.0 s | Complete; 24/24, 71.5 s |
| Catalog | Failed; 12/12 records, wrong total/recommendation, 34.0 s | Failed; only 9/12 specifications read, 33.6 s |

The chain compacted once per arm. Neither catalog run compacted. All 72 tool
calls used `chat_work`; there were no infrastructure/API errors.

## Closing behavior follow-up

The comparison above used closing guidance in the system prompt only. It did
not prevent raw tool-call output at the cap. Replaying the two failed revised
final requests with that same guidance **after the evidence** produced prose
answers in both cases (10.4 s and 6.8 s). Both acknowledged that the requested
fifth page was missing. Those are final-request replays, not full task timings
or successful research completions; their factual claims are not certified.

The current implementation also places that closing guidance after transient
context, outside the saved conversation prefix. Two fresh 8K live runs are
recorded separately: **0/2 complete**, 113.6 s and 46.0 s. Both ended before the
cap (16 and 8 tool calls), so they did **not** exercise the closing instruction.
The first falsely counted a Facebook consent/login screen and a general blog
directory as sources. The second acknowledged missing research but asked whether
to continue despite the original instruction. Thus the closing change has
positive saved-request replay evidence and native wire coverage, but no fresh
end-to-end run reaching the cap. It does not fix premature stopping or source
quality, and these two runs must not be used as evidence that it does.

## Scope, provenance and limitations

- Host: Apple M3 Ultra, 512 GB, macOS 27.0. This is not the report's M4/32 GB host.
- Model: `lmstudio-community/NVIDIA-Nemotron-3.5-Bolt-E4B-MLX-4bit`, revision
  `4274caa99dbacb12cbbca9bd9595a5063a33880f`.
- Runtime: MLX-VLM recovery commit `b4995ba72d46e39e158542062b75737b2230900a`
  (package 0.7.11), MLX 0.32.4, Transformers 5.21.0, Python 3.12.12.
- Baseline Nativ: `409d910af06ac90091466ae279b3417815679be0`, which already
  includes the earlier bounded-tool-output fixes. Revised 22-run comparison:
  `d31bcb0b1f6276862574e6857214369925622662`. Closing follow-up:
  `d9801d6efd5846734334f347fbb4a9b80c536290`.
- Same sampling and runtime settings per arm: temperature 0, thinking off,
  4,096 output tokens, memory prefix cache on, disk cache off, 75% compaction
  threshold. Unload and excluded warmup before every trial. Seeds 123–125;
  trial order reversed in the middle repetition. Temperature zero did not make
  live pages or every final output identical across trials.
- `/v1/responses` replays returned compaction items plus the new canonical tail;
  current evidence is appended separately. Both arms permit 32 tool rounds and
  one final generation without tools. Earlier Chat Completions/prototype runs
  changed route, output allowance and round limit and must not be pooled here.
- The test-only bridge calls the real Chat Work browser and production evidence
  builder. Its nonpersistent browser profile isolates cookies. It exports the
  real `chat_work` schema/session guidance, with a shared research instruction.
  Other tools, work-pane listings, attachments and interactive consent are
  excluded. This is a browser-component evaluation, not full Nativ UI latency.
- Exact excerpts are bounded, restricted to the current user request and taken
  from the start of each page. They cannot preserve arbitrary late-page facts.
  More retained text causes more compaction and prefill. Search/page detection
  is heuristic: an HTTP-200 error page can enter the ledger, and a rendered
  Reddit discussion with a challenge query parameter was excluded. Source
  counts are explicitly observations, not certifications of useful sources.
- The corpus covers synthetic recall/calculation and one live research prompt
  with one small model. It does not establish broad reliability or speedups.

Native validation: 127 unique tests passed; one optional live-compaction test
skipped. Six Python harness tests passed. Coverage includes real WebKit result
ordering, URL search navigation, bounded evidence, compaction-prefix reuse,
closing-message ordering on both API routes and prompt token counting. The
test-only build helper restores modified source files in `finally`.

Raw captures, per-run manual reviews, HTML/JSON summaries, frozen source patches,
source/binary hashes and validation logs are retained in the benchmark artifact.
Pilot and earlier diagnostic trials are excluded from all tables above.
