# Integrations

Nativ serves local models over standard APIs, so external agents and editors that speak OpenAI or
Anthropic can point straight at it. The **Integrations** page writes each tool's configuration
automatically; the per-tool sections below document what each one needs for manual setup.

## Connection details

- OpenAI-compatible base URL: `http://127.0.0.1:8080/v1`
- Anthropic-compatible base URL: `http://127.0.0.1:8080`
- API key: `nativ` by default, or the server API key set on the Welcome screen.
- Model: the repository ID of a loaded model (for example `mlx-community/Qwen3.5-9B-MLX-4bit`).

A different host or port (set in the [Developer](developer.md) page) substitutes everywhere below.

## MCP host

Model Context Protocol servers connect through the Extensions hub's **MCP** section, and their
tools become available to a tool-calling model in [Chat](chat.md).

- Configured servers persist in settings and are (re)started by the host
  ([`MCPHostManager`](../../Sources/Nativ/Features/MCP/MCPHostManager.swift)).
- Each MCP tool call passes through the same consent gate as built-in chat tools before it runs.
- The **Browse catalog** grid lists reviewed community servers; a [Kit](../extending/kits.md)
  can bundle several servers, skills, and extensions and enable them together.

Authoring: add a server to the catalog via [MCP catalog](../extending/mcp-catalog.md); bundle
pieces via [Kits](../extending/kits.md).

## Coding agents

### Pi
Minimal, extensible coding agent.
- Config: `~/.pi/agent/models.json` — a `nativ` provider (`api: openai-completions`,
  `baseUrl: http://127.0.0.1:8080/v1`, `apiKey: nativ`) with the loaded models.
- Run: `pi --provider nativ --model <model-id>`

### Codex
OpenAI coding agent for the terminal.
- Config: `~/.codex/nativ.config.toml`
  ```toml
  model_provider = "nativ"

  [model_providers.nativ]
  base_url = "http://127.0.0.1:8080/v1"
  env_key = "NATIV_API_KEY"
  wire_api = "responses"
  ```
- Run: `NATIV_API_KEY=nativ codex --profile nativ --model <model-id>`

### Claude Code
Anthropic's agentic coding tool. Points at the Anthropic-compatible endpoint.
- Environment: `ANTHROPIC_BASE_URL=http://127.0.0.1:8080`, `ANTHROPIC_AUTH_TOKEN=nativ`,
  `ANTHROPIC_API_KEY=` (empty), `ANTHROPIC_MODEL=<model-id>`, `ANTHROPIC_SMALL_FAST_MODEL=<model-id>`
- Run: `claude --model <model-id>` with the environment above.

### Hermes
Open agent with tools, skills, and memory.
- Config: `~/.hermes/profiles/nativ/config.yaml` — a `custom` provider with
  `base_url: http://127.0.0.1:8080/v1`, `api_key: nativ`, `api_mode: chat_completions`.
- Run: `hermes -p nativ chat --provider custom --model <model-id>`

### OpenCode
Open-source coding agent.
- Config: an `opencode.json` using the `@ai-sdk/openai-compatible` provider `nativ`
  (`baseURL: http://127.0.0.1:8080/v1`, `apiKey: nativ`).
- Run: `OPENCODE_CONFIG=<path> opencode --model nativ/<model-id>`

### Aider
AI pair programming in the terminal.
- Config (env file): `OPENAI_API_BASE=http://127.0.0.1:8080/v1`, `OPENAI_API_KEY=nativ`
- Run: `aider --env-file <path> --model openai/<model-id>`

### Goose
Extensible on-machine AI agent.
- Config: `~/.config/goose/custom_providers/nativ.json` — an `openai` engine provider with
  `base_url: http://127.0.0.1:8080/v1/chat/completions` and `api_key_env: NATIV_API_KEY`.
- Run: `NATIV_API_KEY=nativ GOOSE_MODEL=<model-id> goose session start --provider nativ`

### Crush
Terminal coding agent.
- Config: a `crush.json` with an `openai-compat` provider `nativ`
  (`base_url: http://127.0.0.1:8080/v1`, `api_key: nativ`); large and small models set to `nativ`.
- Run: `CRUSH_GLOBAL_CONFIG=<path> crush`

### Qwen Code
Agentic coding CLI; works with any served model.
- Environment: `OPENAI_BASE_URL=http://127.0.0.1:8080/v1`, `OPENAI_API_KEY=nativ`,
  `OPENAI_MODEL=<model-id>`
- Run: `qwen` with the environment above.

### OpenClaw
Open personal AI agent and gateway.
- Config: `~/.openclaw/openclaw.json` — adds `models.providers.nativ` (`api: openai-completions`,
  `baseUrl: http://127.0.0.1:8080/v1`, `apiKey: nativ`).
- Run: `openclaw agent --model nativ/<model-id>`

## Editors

### Zed
- Config: `~/.config/zed/settings.json` — `language_models.openai_compatible.nativ` with
  `api_url: http://127.0.0.1:8080/v1` and the available models.
- Run: `NATIV_API_KEY=nativ zed .`

### Continue
- Config: a `continue-config.yaml` with `provider: openai`, `apiBase: http://127.0.0.1:8080/v1`,
  `apiKey: nativ`, and roles `chat`, `edit`, `apply`.
- Run: `cn --config <path>`

### VS Code (Copilot BYOK)
1. Start the server and load a model from the Models page.
2. Command Palette → "Chat: Manage Language Models".
3. Choose "OpenAI Compatible", set base URL `http://127.0.0.1:8080/v1` and key `nativ`, then pick
   the model. Requires the GitHub Copilot extension, signed in.

### Cline
1. Install the Cline extension in VS Code (or a compatible editor).
2. Add an API Provider of type "OpenAI Compatible".
3. Set base URL `http://127.0.0.1:8080/v1` and key `nativ`, then select the model.

### Cursor
1. Settings → Models.
2. Enable "Override OpenAI Base URL" and set `http://127.0.0.1:8080/v1` with key `nativ`.
3. Add the model name, then select it in the chat model picker. Only the chat/AI panel honors a
   custom OpenAI endpoint — Tab and inline edits stay on Cursor's own models.

### JetBrains AI Assistant
1. Settings → Tools → AI Assistant → Models.
2. Under Providers & API keys, add an "OpenAI Compatible" provider with base URL
   `http://127.0.0.1:8080/v1` and key `nativ`.
3. Select the model. Requires the AI Assistant plugin.

## Buzz

A self-hostable workspace where people and AI agents share rooms; its agent runtime selects a
provider from environment variables.
- Environment: `BUZZ_AGENT_PROVIDER=openai`, `OPENAI_COMPAT_BASE_URL=http://127.0.0.1:8080/v1`,
  `OPENAI_COMPAT_API_KEY=nativ`, `OPENAI_COMPAT_MODEL=<model-id>` (or `BUZZ_AGENT_MODEL`);
  optional `OPENAI_COMPAT_API=chat` to force Chat Completions.
- Anthropic instead: `BUZZ_AGENT_PROVIDER=anthropic`, `ANTHROPIC_BASE_URL=http://127.0.0.1:8080`,
  `ANTHROPIC_API_KEY=nativ`, `ANTHROPIC_MODEL=<model-id>`.
