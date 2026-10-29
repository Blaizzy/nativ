# Developer

The Developer page runs and inspects the local inference server; the Dashboard and System Monitor
observe it. Sources:
[`Developer/`](../../Sources/Nativ/Features/Developer/),
[`Dashboard/`](../../Sources/Nativ/Features/Dashboard/),
[`SystemMonitor/`](../../Sources/Nativ/Features/SystemMonitor/).

## Server and endpoints

The bundled server listens on `http://127.0.0.1:8080` by default. Host and port are set in the
Developer page (`serverHost` / `serverPort`); the page lists every endpoint and copies URLs
directly. An optional server API key (`serverAPIKey`) is sent as a bearer token.

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer nativ' \
  -d '{"model":"<model-id>","messages":[{"role":"user","content":"Hi"}],"stream":false}'
```

Available routes:

- OpenAI-compatible: `/v1/chat/completions`, `/v1/responses`, `/v1/responses/compact`
  (with a compaction-capable runtime), `/v1/models`, and image, audio, and
  embeddings routes.
- Anthropic-compatible: `/v1/messages` and token-counting routes.
- Operational: `/health`, `/metrics`, cache statistics, cache reset, and model unload.

External tools consume these endpoints — see [Integrations](integrations.md).

## External engines

A model can be served by another OpenAI-compatible engine, such as [Splash](https://github.com/incoai/splash),
while Nativ's server stays the single endpoint for the app, scheduled tasks, and external tools.
List the models in `~/Library/Application Support/Nativ/remote-engines.json`:

```json
{
  "local/Qwen3.8-27B-Uncensored-4bit": {
    "base_url": "http://127.0.0.1:8091/v1",
    "model": "local/Qwen3.8-27B-Uncensored-4bit",
    "api_key": "optional"
  }
}
```

Chat Completions and Responses requests for a listed model are forwarded to its engine and streamed
back, and are recorded in the same analytics as in-process requests. Models not listed run in-process
as before. The file is read per request, so edits apply without a restart. `/v1/responses/compact`
is not forwarded and returns 501 for these models. Model-load settings such as KV-cache bits, prefix
caching, and draft models belong to the engine and have no effect on a forwarded model. Select a
different model for in-process preloading so the server does not also load the forwarded one.

## Hugging Face token

A Hugging Face token enables downloading gated models. Set it in the Developer page or via
`HF_TOKEN`; it is applied to the server environment on start.

## Logs

Live server output is searchable and filterable in the Developer page, alongside runtime details
and server health. Logs are the first place to check when a model fails to load or a request
errors.

## Dashboard (analytics)

The Dashboard reports request volume, token usage, time to first token, decode speed, per-model
performance, and recent activity, backed by
[`NativAnalyticsStore`](../../Sources/Nativ/Features/Dashboard/NativAnalyticsStore.swift). Metrics
are polled from the server's `/metrics` endpoint while it runs.

## System Monitor

The System Monitor reports live hardware state
([`SystemMonitorStore`](../../Sources/Nativ/Features/SystemMonitor/SystemMonitorStore.swift)):

- Per-core CPU load and GPU utilization.
- Unified memory and swap pressure.
- Disk throughput, capacity, and SMART health.
- Thermal and power sensors.

## Menu bar

Menu-bar controls start and stop the server, change the loaded model, show serving statistics,
open the main window without stealing focus, and pin live CPU, GPU, and memory percentages with
mini graphs.
