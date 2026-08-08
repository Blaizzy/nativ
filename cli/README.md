# nativ CLI

> **WIP.** Local AI from your terminal, on the same stack Nativ runs.

A small, standalone Swift package (`swift build`) that talks to the local
mlx-vlm server over its OpenAI-compatible HTTP API. It's **API-first and
decoupled**: the only contract with the app is a small `cli.json` handshake
(flags → env → file → defaults), so Nativ's internals can change without
breaking the CLI, and the same binary works against a local *or* remote server
via `--base-url`.

## Build

```sh
cd cli
swift build          # produces .build/debug/nativ
```

## Commands

| Command | Endpoint / action |
|---|---|
| `nativ run "<prompt>"` | `/v1/chat/completions` (streams); `--model`, `--system`, `--image`, `--json`, stdin |
| `nativ chat` | interactive REPL (`/model`, `/system`, `/reset`, `/help`, `/exit`, `"""` multiline) |
| `nativ serve` / `nativ stop` | launch/stop the bundled `mlx-vlm-server`; `serve -d` waits until ready |
| `nativ status` | server health + `/v1/models` |
| `nativ models list \| use \| pull \| rm` | list loaded + locally-cached models, set default, download (HF), remove |
| `nativ embed` | `/v1/embeddings` (JSON, or `--dims`) |
| `nativ image "<prompt>"` | `/v1/images/generations` → saves a file |
| `nativ transcribe <file>` | multipart `/v1/audio/transcriptions` |
| `nativ audio speak "<text>"` | `/v1/audio/speech` → saves an audio file (audio group grows with the server) |
| `nativ config show \| set \| path` | read/write `cli.json` |
| `nativ agent [--json]` | full reference for coding agents |

## Configuration

Resolved in order: command flags → environment → `cli.json` → defaults, per
setting. The app is expected to write `cli.json` so the CLI auto-syncs with no
flags; `nativ config set …` writes it standalone.

| Setting | Flag | Env | `cli.json` |
|---|---|---|---|
| base URL | `--base-url` | `NATIV_BASE_URL` | `baseURL` |
| API key | `--api-key` | `NATIV_API_KEY` | `apiKey` |
| chat/VLM model | `--model` | `NATIV_MODEL` | `defaultModel` |
| embedding model | `--model` | `NATIV_EMBEDDING_MODEL` | `embeddingModel` |
| image model | `--model` | `NATIV_IMAGE_MODEL` | `imageModel` |
| STT model | `--model` | `NATIV_STT_MODEL` | `sttModel` |
| TTS model | `--model` | `NATIV_TTS_MODEL` | `ttsModel` |
| model search path | — | `NATIV_MODEL_PATH` | `modelSearchPath` |
| server binary | — | `NATIV_SERVER_BIN` | — |

Per-capability models fall back to the chat model when unset.

## Design

- **Contract = the server HTTP API.** The CLI carries its own tiny HTTP client;
  no dependency on Nativ's Swift internals.
- **Command registry.** Each command is one self-contained file — adding a
  command is a new file, no cross-cutting changes.
- **Server launch** uses the bundled `mlx-vlm-server` at a stable resource path.

## Tests

```sh
cd cli
swift test          # requires a full Xcode toolchain (XCTest)
```

Unit tests cover SSE parsing, multipart framing, and per-capability model
resolution.

## Known TODOs (WIP)

- `models pull` shells out to `huggingface-cli`; align with the app's cache layout.
- `mcp` (list/call tools) deferred — needs a server-side MCP contract; it's
  orchestrated app-side today.
- App-side: write `cli.json`; add an "Install `nativ` command" PATH shim.
