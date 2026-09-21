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

- OpenAI-compatible: `/v1/chat/completions`, `/v1/responses`, `/v1/models`, and image, audio, and
  embeddings routes.
- Anthropic-compatible: `/v1/messages` and token-counting routes.
- Operational: `/health`, `/metrics`, cache statistics, cache reset, and model unload.

External tools consume these endpoints — see [Integrations](integrations.md).

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
