# Nativ — Feature Support Matrix

<!-- Generated from nativ.yml by scripts/render_manifest.py. Do not edit by hand. -->

Status: **Shipped** (in the current release) · **Experimental** (usable but unstable / in active development) · **Planned** (committed) · **Exploratory** (under investigation).

## Capabilities

| Capability | Status | Provider | Notes |
| --- | --- | --- | --- |
| Advanced inference controls | Shipped | mlx-vlm | Sampling, thinking budgets, structured output, KV-cache quantization, prefix caching, and speculative decoding. |
| Anthropic-compatible API | Shipped | mlx-vlm | /v1/messages and /v1/messages/count_tokens. |
| Coding-tool integrations | Shipped | nativ | Configure and launch Codex, Claude Code, Pi, Hermes, and OpenCode against models served by Nativ. |
| Developer workspace | Shipped | nativ | Runtime details, copyable endpoint URLs, live server-log search/filter, and server-health monitoring. |
| Local chat & vision | Shipped | mlx-vlm | Streaming conversations, image attachments, reasoning output, response metrics, and persistent chat history. |
| Menu bar controls | Shipped | nativ | Start/stop the server, change the loaded model, check serving stats, and open the app without breaking focus. |
| Model library | Shipped | mlx-vlm | Discover installed MLX models, browse compatible Hugging Face models, download, inspect capabilities, switch, or remove. |
| OpenAI-compatible API | Shipped | mlx-vlm | /v1/chat/completions, /v1/responses (+ input_tokens, cancel, input_items), /v1/models. |
| Performance analytics | Shipped | nativ | Request volume, token usage, time-to-first-token, decode speed, per-model performance, and recent activity. |
| Custom local server port | Experimental | nativ | Choose the local server port from the Developer page (in progress on feature/custom-server-port; not yet on main). |
| Dedicated audio models (speech recognition & speech generation) | Planned (0/6) | mlx-audio | Coming soon. API surface (/v1/audio/*) is present; the dedicated audio-model runtime is not yet integrated. (#15) |
| Dedicated embedding models | Planned (0/6) | mlx-embeddings | Not yet supported. Requires bundling mlx-embeddings and a dedicated embedding runtime. (#16) |
| Dedicated image-generation models | Planned (0/8) | mlx-vlm | Coming soon. /v1/images/* routes and the ImageGeneration workspace are scaffolded; the dedicated diffusion runtime and memory-aware fit estimate are not yet complete. (#14 #44 #46) |
| Gated Hugging Face model downloads | Planned | nativ | Authenticate with Hugging Face to download license-gated / access-requested models from within Nativ. (#23) |
| Model metadata in /v1/models (context window, tools, vision) | Planned (0/4) | mlx-vlm | Expose per-model max context window and tool/function-calling and vision support in /v1/models so OpenAI-compatible clients (e.g. the community VSCode extension) need not hardcode them. (#56) |

## Runtime providers

| Provider | Role | Version | Repo |
| --- | --- | --- | --- |
| mlx-vlm | bundled | `>=0.6.5` | Blaizzy/mlx-vlm |
| mlx-audio | bundled | `==0.4.3` | Blaizzy/mlx-audio |
| mlx-embeddings | planned | `—` | Blaizzy/mlx-embeddings |

## Platform

- Apple silicon: **required** (M1 or later)
- Minimum macOS: **26.0**

See [ROADMAP.md](ROADMAP.md) for planned work and [CHANGELOG.md](CHANGELOG.md) for release history. Tracked in [Blaizzy/nativ issues](https://github.com/Blaizzy/nativ/issues).
