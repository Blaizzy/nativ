# Chat Work research recovery — 27 October 2026

The revised existing `chat_work` path preserves exact facts better across
compaction, at additional latency. It does **not** reliably finish open-ended
research with this model. These results support a draft for further evaluation,
not a claim that the original browsing report is fully resolved.

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
