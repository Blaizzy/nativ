# Chat Work browser command experiment

The opt-in `Nativ --browser-stdio` bridge accepts one JSON object per line and returns
one JSON result per line. It runs Chat Work's actual WebKit browser, navigation/error
handling and cookie profile. It does not start a model server or require a search API
key. This is a prototype; ordinary chat tool registration is unchanged.

```json
{"name":"browser_search","arguments":{"query":"local OCR models"},"context":8192}
{"name":"browser_read","arguments":{"url":"https://example.com/source"},"context":8192}
```

Reads return `next_offset` for continuation, plus source links. Reuse the same process
for subsequent calls. `{"name":"tools"}` exports the exact flat and generic schemas.
The `chat_work` command accepts existing browser actions for the baseline and for
operator-assisted interaction with a consent page. Non-browser actions are rejected.

The CLI owns its own tabs. It uses the app's persistent cookie profile by default;
it does not attach to an already open chat's tab. Set `NATIV_BROWSER_PROFILE` to a
fresh UUID to isolate a benchmark, and `NATIV_BROWSER_VISIBLE=1` to display its window.
A CLI does not bypass consent or CAPTCHA. Search failure is returned explicitly.

## Matched long-horizon evaluation

Build with Xcode. Run `run_suite.py` using a Python environment containing the tested
MLX-VLM revision, passing `--binary /path/to/Nativ.app/Contents/MacOS/Nativ`,
`--model /path/to/checkpoint`, and `--output /path/to/results`.

- Same checkpoint, tokenizer, host, runtime, temperature zero, thinking disabled,
  memory prefix caching enabled, disk cache disabled, and 2,048 output tokens.
- 8K and 16K contexts; three trials per interface, reversing order in the middle
  repetition. Each trial unloads the model and performs an excluded warmup.
- Generic arm: the real `chat_work` schema. Compact arm: `browser_search` and
  `browser_read`. Both use the same browser engine and Google readiness check.
- Two controlled HTTP fixtures: a 24-page dependent link chain with ordered recall
  and an unknown-fact check; a 12-page catalog requiring every record and an exact
  constrained recommendation. Facts are served only in pages, never in the prompt.
- The original live OCR request is tested at 8K. Search snippets are never counted as
  page reads. Its automatic grade checks five source visits and a final answer only;
  source quality, accuracy and comparison usefulness require manual review.
- Record full messages, tool calls/results, streaming usage, TTFT, wall time, health,
  fixture hash, exact schemas and environment. Do not treat fixture success as proof
  of live research quality, or a fast failure as a speed improvement.

This compares browser-tool components, not complete Nativ UI latency or every tool
advertised by the app. The baseline includes the current context bounds and shortened
instructions; it is not the original 0.4.3 release. Live results can vary over time.
