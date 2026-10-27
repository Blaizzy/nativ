# Chat Work browser CLI: measured results

27 October 2026. The compact interface substantially reduces the initial prompt,
but these trials do not support enabling it in ordinary chat. It completed fewer
24-page recall tasks, and neither interface completed the live OCR request under
the evaluation's limits. The prototype remains opt-in through `--browser-stdio`.

## Conditions

- Apple M3 Ultra, 512 GB, macOS 27.0; inference and WebKit on the same machine.
- `lmstudio-community/NVIDIA-Nemotron-3.5-Bolt-E4B-MLX-4bit`, revision
  `4274caa99dbacb12cbbca9bd9595a5063a33880f`.
- MLX-VLM recovery commit `b4995ba72d46e39e158542062b75737b2230900a`
  (package reports 0.7.11), MLX 0.32.4, Transformers 5.21.0, Python 3.12.12.
- Browser implementation at Nativ commit `d537e33dd1c75a0bac8e6fb4af15cfca0178bc9c`,
  based on `409d910af06ac90091466ae279b3417815679be0`.
  Tested debug library SHA-256:
  `cfbe0ec727f280ac02ef6464faf3ff54bd989e3f4cc761df19469b7693946872`.
- Temperature 0, thinking disabled, memory prefix cache enabled, disk cache
  disabled. Unload and an excluded warmup before every trial. A fresh cookie
  profile per browser process; no search API key.
- Full-history `/v1/chat/completions` requests, runtime compaction enabled,
  8,192 or 16,384 context tokens, 2,048 maximum output tokens per request.
- Three trials per condition, seeds 123/124/125, alternating interface order in
  the middle repetition. Fixture tasks allow 36 model rounds; live research
  allows 20. Each task has a 30-minute deadline.

The generic interface exposes the real `chat_work` schema. The compact interface
exposes only `browser_search` and `browser_read`. Both execute Chat Work's WebKit
browser and share the same Google readiness check. The generic arm already has
the context bounds and shorter guidance from the preceding fix; it is not the
original 0.4.3 release. This evaluates the tool interface and returned content
together, without isolating their individual effects.

## Primary results: 30 runs

Times below are medians across **all** trials, including failures. A shorter
failed task is not evidence of a speed improvement.

| Task | Context | Generic completed | Compact completed | Generic seconds | Compact seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| 24-page dependent chain | 8K | 2/3 | 0/3 | 38.1 | 20.2 |
| 24-page dependent chain | 16K | 2/3 | 1/3 | 29.1 | 23.5 |
| 12-page catalog | 8K | 0/3 | 0/3 | 38.2 | 33.7 |
| 12-page catalog | 16K | 0/3 | 0/3 | 33.7 | 32.7 |
| Live five-page OCR research | 8K | 0/3 | 0/3 | 65.0 | 69.5 |

All fixture trials visited every required page. Chain completion requires all 24
tokens in order and `null` for the unknown passport number. At 8K, compact trials
recalled 6/24 known tokens each; generic trials recalled 24, 24 and 3. At 16K,
compact recalled 8, 8 and 24; generic recalled 9, 24 and 24. These partial counts
measure known values retained, separately from the exact completion grade.

Catalog completion requires every record, the correct latency total and the
fastest CPU-supported Apache-2.0 model. Five of the 12 primary catalog answers hit
the output limit (four compact, one generic); other failures include invented
record identifiers, incorrect facts and incorrect recommendations.

The compact live arm produced one final answer after only three distinct page
payloads and explicitly relaxed the five-page requirement. Its other two trials,
and all three generic trials, reached the 20-round limit without a final answer.
Some visited URLs returned interstitials or error content. Raw page-payload counts
therefore overstate usable sources; no live trial receives completion credit.

Initial prompt tokens fell from 1,591 to 408 for the chain, 1,598 to 415 for the
catalog, and 1,533 to 350 for live OCR: a 74–77% reduction. Fixture tool-output
volume only fell approximately 2–4%, because the baseline already caps results.
The reduction in initial instructions did not resolve evidence retention or
task completion.

## Separate output-budget diagnostic: four runs

One catalog trial per interface and context, with 4,096 output tokens. These are
not included in the primary success rates or timing medians.

| Context | Interface | Correct records | Correct total | Correct recommendation | Completed |
| --- | --- | ---: | --- | --- | --- |
| 8K | Generic | 0/12 | No | No | No |
| 8K | Compact | 5/12 | No | No | No |
| 16K | Generic | 12/12 | No | No | No |
| 16K | Compact | 12/12 | Yes | No | No |

No diagnostic answer hit the output limit. At 16K both selected Scanner-09, which
has a restricted license. The correct recommendation is Scanner-01; the correct
total is 2,722 ms. Increasing the output allowance helped record extraction at
16K but did not make either run correct end to end.

## Evidence and limits

All 34 runs finished without an infrastructure exception. Captures contain full
messages, exact tool schemas, tool arguments/results, streaming events, usage,
TTFT, source URLs, fixture hashes and runtime health. Health confirmed the requested
context and enabled prefix cache in every trial. An audit of all 606 tool calls
found no calls outside the advertised interface. A subsequently added tool-name
guard therefore does not change these measurements. Stricter rejection of extra
fixture records/tokens also leaves all measured completion grades unchanged.

The primary and diagnostic runners are preserved separately with the evidence;
the diagnostic added a configurable output allowance. Reports can be regenerated
using `summarize.py`. Preliminary runs used to fix tab reuse and Google's opaque
result redirects are excluded from these results.

This is one model on one machine, with three primary trials per condition.
Reported prompt-token sums exclude internal summary generations. Prompt drops
are not exact compaction counters. The harness uses full-history Chat Completions,
not Nativ's Responses replay, and does not measure full app UI latency or the
reporter's M4 machine. The generic CLI supports browser actions only, even though
the generic schema also advertises other work actions.

The live gate checks five distinct non-search page payloads plus a final answer;
it does not establish source relevance or answer accuracy. A round-limit failure
does not establish that a model could never finish. Live search results can change.
The CLI still uses Google in WebKit, so consent and challenges remain possible.

The next experiment should test preserving explicit source notes and task progress
through compaction, along with a completion check that enforces the requested
source count. These changes are not implemented by this prototype.

## Validation

- 99 selected native tests passed across browser commands, browser execution,
  Chat Work and tool registration. The four command tests passed again after the
  Google redirect correction.
- Three Python grading tests passed, covering required source visits, ordered
  recall, unknown facts and duplicate visits.
- A real Google search returned extracted results, and following an opaque
  result redirect returned the final source URL and rendered article text.
- Python compilation and `git diff --check` passed. Normal chat registration and
  Python dependency requirements are unchanged by this experiment.
