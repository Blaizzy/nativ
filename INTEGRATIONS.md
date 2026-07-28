# Integrations

Nativ serves your local models over standard APIs, so agents and editors that speak
OpenAI or Anthropic can point straight at it:

- OpenAI-compatible base URL: `http://127.0.0.1:8080/v1`
- Anthropic-compatible base URL: `http://127.0.0.1:8080`
- API key: `nativ` by default, or the server API key you set on the Welcome screen.
- Model: the repository ID of a model you have loaded (for example `mlx-community/Qwen3.5-9B-MLX-4bit`).

If your server host or port differs, substitute it everywhere below. The Integrations page
sets all of this up for you; the sections here document what each tool needs so you can
configure it by hand or see exactly what Nativ writes.

## Pi

Minimal, extensible coding agent.

- Config: `~/.pi/agent/models.json` — adds a `nativ` provider (`api: openai-completions`,
  `baseUrl: http://127.0.0.1:8080/v1`, `apiKey: nativ`) with your loaded models.
- Run: `pi --provider nativ --model <model-id>`

## Codex

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

## Claude Code

Anthropic's agentic coding tool. Points at the Anthropic-compatible endpoint.

- Environment:
  - `ANTHROPIC_BASE_URL=http://127.0.0.1:8080`
  - `ANTHROPIC_AUTH_TOKEN=nativ`
  - `ANTHROPIC_API_KEY=` (empty)
  - `ANTHROPIC_MODEL=<model-id>`, `ANTHROPIC_SMALL_FAST_MODEL=<model-id>`
- Run: `claude --model <model-id>` with the environment above.

## Hermes

Open agent with tools, skills, and memory.

- Config: `~/.hermes/profiles/nativ/config.yaml` — a `custom` provider with
  `base_url: http://127.0.0.1:8080/v1`, `api_key: nativ`, `api_mode: chat_completions`.
- Run: `hermes -p nativ chat --provider custom --model <model-id>`

## OpenCode

Open-source coding agent.

- Config: an `opencode.json` using the `@ai-sdk/openai-compatible` provider `nativ`
  (`baseURL: http://127.0.0.1:8080/v1`, `apiKey: nativ`).
- Run: `OPENCODE_CONFIG=<path> opencode --model nativ/<model-id>`

## Aider

AI pair programming in your terminal.

- Config (env file): `OPENAI_API_BASE=http://127.0.0.1:8080/v1`, `OPENAI_API_KEY=nativ`
- Run: `aider --env-file <path> --model openai/<model-id>`

## Goose

Extensible on-machine AI agent.

- Config: `~/.config/goose/custom_providers/nativ.json` — an `openai` engine provider with
  `base_url: http://127.0.0.1:8080/v1/chat/completions` and `api_key_env: NATIV_API_KEY`.
- Run: `NATIV_API_KEY=nativ GOOSE_MODEL=<model-id> goose session start --provider nativ`

## Crush

Glamorous terminal coding agent.

- Config: a `crush.json` with an `openai-compat` provider `nativ`
  (`base_url: http://127.0.0.1:8080/v1`, `api_key: nativ`); large and small models set to `nativ`.
- Run: `CRUSH_GLOBAL_CONFIG=<path> crush`

## Qwen Code

Agentic coding CLI tuned for Qwen — works with any model served here.

- Environment: `OPENAI_BASE_URL=http://127.0.0.1:8080/v1`, `OPENAI_API_KEY=nativ`,
  `OPENAI_MODEL=<model-id>`
- Run: `qwen` with the environment above.

## OpenClaw

Open personal AI agent and gateway.

- Config: `~/.openclaw/openclaw.json` — adds `models.providers.nativ`
  (`api: openai-completions`, `baseUrl: http://127.0.0.1:8080/v1`, `apiKey: nativ`).
- Run: `openclaw agent --model nativ/<model-id>`

## Zed

High-performance, multiplayer code editor.

- Config: `~/.config/zed/settings.json` — adds
  `language_models.openai_compatible.nativ` with `api_url: http://127.0.0.1:8080/v1` and
  your available models.
- Run: `NATIV_API_KEY=nativ zed .`

## Continue

Open-source AI code assistant.

- Config: a `continue-config.yaml` with `provider: openai`,
  `apiBase: http://127.0.0.1:8080/v1`, `apiKey: nativ`, and roles `chat`, `edit`, `apply`.
- Run: `cn --config <path>`

## VS Code

Copilot BYOK via an OpenAI-compatible endpoint.

1. Start Nativ's server and load a model from the Models page.
2. Open the Command Palette and run "Chat: Manage Language Models".
3. Choose "OpenAI Compatible", set the base URL `http://127.0.0.1:8080/v1` and key `nativ`,
   then pick your model.

Copilot BYOK requires the GitHub Copilot extension, signed in.

## Cline

OpenAI-compatible provider in the Cline extension.

1. Install the Cline extension in VS Code (or a compatible editor).
2. Open Cline's settings and add an API Provider of type "OpenAI Compatible".
3. Set the base URL `http://127.0.0.1:8080/v1` and key `nativ`, then select your model.

## Cursor

OpenAI-compatible endpoint in Cursor's AI panel.

1. Open Settings → Models.
2. Enable "Override OpenAI Base URL" and set `http://127.0.0.1:8080/v1` with key `nativ`.
3. Add your model name, then select it in the chat model picker.

Only Cursor's chat/AI panel honors a custom OpenAI endpoint — Tab and inline edits stay on
Cursor's own models.

## JetBrains

OpenAI-compatible endpoint in JetBrains AI Assistant.

1. Open Settings → Tools → AI Assistant → Models.
2. Under Providers & API keys, add an "OpenAI Compatible" provider with base URL
   `http://127.0.0.1:8080/v1` and key `nativ`.
3. Select your model, then use it from the AI Assistant chat.

Requires the AI Assistant plugin (recent JetBrains IDE versions).

## Buzz

A self-hostable workspace where people and AI agents share the same rooms. Buzz's agent
runtime selects its model provider from environment variables, so it can run against Nativ's
OpenAI-compatible endpoint instead of a hosted provider.

- Environment:
  - `BUZZ_AGENT_PROVIDER=openai`
  - `OPENAI_COMPAT_BASE_URL=http://127.0.0.1:8080/v1`
  - `OPENAI_COMPAT_API_KEY=nativ`
  - `OPENAI_COMPAT_MODEL=<model-id>` (or `BUZZ_AGENT_MODEL=<model-id>` to override)
  - Optional: `OPENAI_COMPAT_API=chat` to force Chat Completions instead of Responses.
- Set these where Buzz's agent runs, then start Buzz — its agent will use your local model.

Buzz can also target Nativ's Anthropic-compatible endpoint: set
`BUZZ_AGENT_PROVIDER=anthropic`, `ANTHROPIC_BASE_URL=http://127.0.0.1:8080`,
`ANTHROPIC_API_KEY=nativ`, and `ANTHROPIC_MODEL=<model-id>`.
