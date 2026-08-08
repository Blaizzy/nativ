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
| `nativ run "<prompt>"` | `/v1/chat/completions` (streams); `--model`, `--system`, `--image`, stdin |
| `nativ chat` | interactive REPL (`/reset`, `/exit`) |
| `nativ serve` / `nativ stop` | launch/stop the bundled `mlx-vlm-server` (pidfile) |
| `nativ status` | server health + `/v1/models` |
| `nativ models list \| use \| pull \| rm` | list, set default (writes `cli.json`), download (HF), remove |
| `nativ embed` | `/v1/embeddings` (JSON, or `--dims`) |
| `nativ image "<prompt>"` | `/v1/images/generations` → saves a file |
| `nativ transcribe <file>` | multipart `/v1/audio/transcriptions` |

## Configuration

Resolved in order: command flags → environment (`NATIV_BASE_URL`,
`NATIV_API_KEY`, `NATIV_MODEL`, `NATIV_MODEL_PATH`, `NATIV_SERVER_BIN`) →
`~/Library/Application Support/Nativ/cli.json` → defaults. The app is expected
to write `cli.json` so the CLI auto-syncs with no flags.

## Design

- **Contract = the server HTTP API.** The CLI carries its own tiny HTTP client;
  no dependency on Nativ's Swift internals.
- **Command registry.** Each command is one self-contained file — adding a
  command is a new file, no cross-cutting changes.
- **Server launch** uses the bundled `mlx-vlm-server` at a stable resource path.

## Known TODOs (WIP)

- `serve -d` is best-effort background (logs to `server.log`); full
  daemonization (setsid) pending.
- `models pull`/`rm` assume the model-search-path layout and shell out to
  `huggingface-cli`; align with the app's cache layout.
- `mcp` (list/call tools) deferred — needs a server-side MCP contract; it's
  orchestrated app-side today.
- App-side: write `cli.json`; add an "Install `nativ` command" PATH shim.
