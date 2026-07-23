# Nativ — Feature Support Matrix

<!-- Generated from nativ.yml by scripts/render_manifest.py. Do not edit by hand. -->

Status: **Shipped** (in the current release) · **Experimental** (usable but unstable / in active development) · **Planned** (committed) · **Exploratory** (under investigation).

## Capabilities

| Capability | Status | Provider | Notes |
| --- | --- | --- | --- |
| Advanced inference controls | Shipped | mlx-vlm | Sampling, thinking budgets, structured output, KV-cache quantization, prefix caching, and speculative decoding. |
| Anthropic-compatible API | Shipped | mlx-vlm | /v1/messages and /v1/messages/count_tokens. |
| Coding-tool integrations | Shipped | nativ | Configure and launch Codex, Claude Code, Pi, Hermes, and OpenCode against models served by Nativ. |
| Custom local server port | Shipped | nativ | Choose the local server port from the Developer page (PRs |
| Developer workspace | Shipped | nativ | Set the server port, add a Hugging Face token for gated models, inspect runtime details, copy endpoint URLs, search/filter live server logs, and monitor server health. |
| Gated Hugging Face model downloads | Shipped | nativ | Add a Hugging Face token (in the Developer view or via HF_TOKEN) to download gated models (PR (#23) |
| Local chat & vision | Shipped | mlx-vlm | Streaming conversations, image attachments (including clipboard paste and screenshot capture, PR |
| Menu bar controls | Shipped | nativ | Start/stop the server, change the loaded model, check serving stats, and open the app without breaking focus. |
| Model library | Shipped | mlx-vlm | Discover installed MLX models (including those installed by LM Studio, PR |
| OpenAI-compatible API | Shipped | mlx-vlm | /v1/chat/completions, /v1/responses (+ input_tokens, cancel, input_items), /v1/models. |
| Performance analytics | Shipped | nativ | Request volume, token usage, time-to-first-token, decode speed, per-model performance, and recent activity. |
| Dedicated audio models (speech recognition & speech generation) | Planned (0/6) | mlx-audio | Coming soon. API surface (/v1/audio/*) is present; the dedicated audio-model runtime is not yet integrated. (#15) |
| Dedicated embedding models | Planned (0/6) | mlx-embeddings | Not yet supported. Requires bundling mlx-embeddings and a dedicated embedding runtime. (#16) |
| Dedicated image-generation models | Planned (1/8) | mlx-vlm | Coming soon. /v1/images/* routes and the ImageGeneration workspace are scaffolded; the dedicated diffusion runtime and memory-aware fit estimate are not yet complete. (#14 #44 #46) |
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
