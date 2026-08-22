# Nativ documentation

Reference documentation for Nativ — a native macOS workspace for running AI models
locally on Apple silicon. Each feature page explains what the feature is, how it
works, how it is configured, and where its data and settings live.

For running Nativ, building from source, and the project layout, see the
[repository README](../README.md).

## Features

| Page | Covers |
|---|---|
| [Chat](features/chat.md) | Conversations, sessions and folders, model and tool consent, image generation, and the artifacts gallery. |
| [Models](features/models.md) | Model discovery, downloads, capabilities, per-model configuration, speculative decoding, and how the server loads a model. |
| [Voice](features/voice.md) | Voice dictation, global shortcuts, hands-free and push-to-talk capture, transcription, and permissions. |
| [Scheduled](features/routines.md) | Saved prompts that run on a schedule with task-specific capabilities. |
| [Integrations](features/integrations.md) | Serving local models over OpenAI- and Anthropic-compatible APIs, MCP host usage, and per-tool coding-agent and editor setup. |
| [Developer](features/developer.md) | Local server port and authentication, API endpoints, logs, performance analytics, and the system monitor. |

## Extending Nativ

| Page | Covers |
|---|---|
| [Extensions](extending/extensions.md) | The extension package format, manifest, lifecycle, permissions, and adding a first-party extension. |
| [Kits](extending/kits.md) | Authoring a Kit — a curated bundle of MCP servers, skills, and extensions. |
| [MCP catalog](extending/mcp-catalog.md) | Contributing a server to the built-in MCP list. |
