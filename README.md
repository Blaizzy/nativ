<p align="center">
  <img src="Design/NativBanner.png" alt="Nativ banner" width="100%">
</p>

<h1 align="center">Nativ</h1>

<p align="center">
  <strong>Local AI, native to your Mac.</strong>
</p>

<p align="center">
  Chat, serve, monitor, and connect MLX models from one macOS app.
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple&logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-required-111111?logo=apple&logoColor=white">
  <img alt="Swift 5" src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white">
  <img alt="MLX" src="https://img.shields.io/badge/Powered%20by-MLX-6E5AE6">
</p>

Nativ is a native macOS workspace for running AI models locally on Apple silicon. It bundles an [`mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) server, finds compatible models in your Hugging Face cache (honoring `HF_HUB_CACHE` and `HF_HOME`), and wraps the whole experience in a polished SwiftUI app.

Use Nativ as a private chat app, a model manager, a performance dashboard, or an OpenAI- and Anthropic-compatible local inference server for the tools you already use.

## What Nativ can do

| Feature | What you get |
|---|---|
| **Local chat and vision** | Streaming conversations, image attachments, reasoning output, response metrics, and persistent chat history. |
| **Image generation and editing** | Generate and edit images locally with compatible MLX image models in a dedicated Images tab. |
| **Model library** | Discover installed MLX models, browse and download compatible models from Hugging Face with fit warnings for your memory, inspect capabilities, switch models, or remove old ones. Preload separate language, image-generation, and speech models at once, with a warning if the combination would exceed your Mac's memory. |
| **Performance analytics** | Track request volume, token usage, time to first token, decode speed, model performance, and recent activity. |
| **System monitor** | Inspect live per-core CPU load, GPU utilization, unified memory and swap pressure, disk throughput, capacity, and SMART health. |
| **Local APIs** | OpenAI-compatible chat, Responses, image, audio, and model endpoints, plus Anthropic Messages endpoints. |
| **Coding-tool integrations** | Configure and launch terminal coding agents — Codex, Claude Code, Pi, Hermes, OpenCode, Aider, Goose, Crush, Qwen Code, OpenClaw — and set up editors — VS Code, Cursor, Zed, JetBrains, Cline, Continue — against models served by Nativ. See [INTEGRATIONS.md](INTEGRATIONS.md) for per-tool setup. |
| **Developer workspace** | Set the server host and port, add a Hugging Face token for gated models, inspect runtime details, copy endpoint URLs, search and filter live server logs, and monitor server health. |
| **Menu bar controls** | Start or stop the server, change the loaded model, check serving statistics, open the main app without breaking focus, or pin multiple live CPU, GPU, and RAM percentages and mini graphs. |
| **Extension platform** | Install, disable, remove, and restore independently versioned capabilities. Audio ships as the first included extension and contributes its own pages, commands, shortcuts, settings, and permission declarations. |
| **Audio extension** | Use private local audio capabilities, including voice dictation in any app with either a pointer-following waveform or a camera-cutout pill with a reactive gradient orb and timer. Review transcript history, track words per minute, total words, time saved, and streaks, choose an installed speech model, and customize the record and retry shortcuts. |
| **Advanced inference controls** | Tune sampling, thinking budgets, structured output, KV-cache quantization, prefix caching, and speculative decoding. |

Inference runs on your Mac after a model has been downloaded. Model downloads and first-time build dependencies still require network access.

## How it works

```mermaid
flowchart LR
    A["Nativ · SwiftUI app"] --> B["NativServerKit"]
    B --> C["Bundled mlx-vlm server"]
    C --> D["MLX runtime"]
    D --> E["Local models · Apple unified memory"]
    F["Apps and coding agents"] -->|"localhost API"| C
```

`NativServerKit` owns the embedded Python distribution and server lifecycle. The app adds model discovery, chat, analytics, configuration, integrations, logs, menu bar controls, and software updates around that runtime.

## Requirements

To run the app:

- A Mac with Apple silicon.
- macOS 26 or newer.
- Enough unified memory for the model you choose.
- Optional: a Hugging Face token (set in the app or via `HF_TOKEN`) to download gated models.

To build from source, you will also need:

- Xcode with the macOS 26 SDK.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen).
- Python 3.
- Network access to GitHub Releases and PyPI while the embedded Python bundle is first assembled or refreshed.

## Get started

### Download a release

Download the latest DMG from [GitHub Releases](https://github.com/Blaizzy/nativ/releases/latest), drag **Nativ** to Applications, and launch it. Nativ uses Sparkle for subsequent in-app updates.

On first launch:

1. Choose an installed language model, download a recommended one, or continue with load-on-demand.
2. Optionally generate an API key to protect the server's management endpoints.
3. Open **Models** to download or select a compatible model.
4. Start chatting, inspect analytics, or connect one of the supported coding tools.

Nativ asks for Accessibility permission so it can detect the default Control + Option + Command
double-tap outside the app, and for Microphone permission the first time you record. Recordings are
saved temporarily as `.wav` files with matching `.txt` transcripts and can be opened from
**Show Voice Recordings** in the menu-bar menu. Raw audio is deleted automatically after five
minutes (or immediately when Nativ quits), while transcript files remain available. Press
Fn + R to transcribe the newest available audio again and insert it at the current cursor.
The transcript remains on the clipboard. If no speech-to-text model is installed, Nativ
links directly to filtered speech-model discovery. Open **Audio** to inspect dictation
analytics and history, select an installed speech-to-text model, choose the capture
animation, or change either global shortcut.

### Build from source

```sh
brew install xcodegen
make xcode-generate
make xcode-run
```

The first build can take a while because `NativServerKit` creates a relocatable Python runtime and installs the pinned `mlx-vlm` server dependencies into the framework resources. Later builds reuse the bundle until an input changes.

Local builds are signed with the Apple Development identity configured in
`Configuration/Signing.xcconfig` (or the ignored
`Configuration/Signing.local.xcconfig` override). Keep the identity's login
keychain unlocked while building. The stable signer-bound identity lets macOS
keep Accessibility permission across rebuilds instead of treating each binary
as a different app.

To test an unreleased `mlx-audio` checkout, point the build at its local path:

```sh
MLX_AUDIO_SOURCE_PATH=/path/to/mlx-audio make xcode-build
```

The local package participates in dependency resolution, so its `pyproject.toml` metadata
replaces the published package metadata. A sibling `../mlx-audio` checkout on the `main`
branch is detected automatically, matching the existing local `mlx-vlm` behavior.

## Use Nativ as a local API server

By default, the app exposes its server at `http://127.0.0.1:8080`. You can change the host and port in the Developer page, which also lists every available endpoint and lets you copy URLs directly.

For example, with a model selected:

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "your-model-id",
    "messages": [{"role": "user", "content": "Why is the sky blue?"}],
    "stream": false
  }'
```

If you enabled a server API key, also send it as a Bearer token:

```sh
-H 'Authorization: Bearer your-api-key'
```

The server includes:

- OpenAI-compatible `/v1/chat/completions`, `/v1/responses`, `/v1/models`, image, and audio routes.
- Anthropic-compatible `/v1/messages` and token-counting routes.
- `/health`, `/metrics`, cache statistics, cache reset, and model unload endpoints.

## Project layout

```text
Sources/
├── Nativ/                       # SwiftUI application
│   ├── Features/
│   │   ├── Chat/
│   │   ├── Dashboard/
│   │   ├── Developer/
│   │   ├── Extensions/         # Extension registry, broker, and management UI
│   │   ├── ImageGeneration/
│   │   ├── Integrations/
│   │   ├── Models/
│   │   ├── VoiceCapture/
│   │   └── SystemMonitor/
│   ├── Assets.xcassets/
│   ├── ModelProviderIcons/
│   └── Utilities/
├── NativExtensionSDK/           # Versioned extension manifests and XPC contracts
└── NativServerKit/              # Embedded server and Swift clients
Extensions/
└── VoiceDictation/              # Audio extension (legacy internal target name)
PythonDistribution/
├── Launcher/                    # Relocatable server launcher
├── Requirements/                # Pinned Python dependencies
└── Scripts/                     # Bundle assembly and verification
Configuration/                   # App metadata and signing settings
Design/                          # Brand source files and README artwork
scripts/                         # Archive, signing, notarization, and release tools
project.yml                      # XcodeGen project definition
```

See [Docs/Extensions.md](Docs/Extensions.md) for the extension package format,
lifecycle, permission model, and the steps for adding another first-party extension.

## Development

### Build and smoke tests

Generate and build the Xcode project:

```sh
make xcode-generate
make xcode-build
```

Verify that the bundled executable can launch and print `mlx_vlm.server` help:

```sh
make xcode-smoke
```

Exercise the long-running process lifecycle and `/metrics` readiness:

```sh
make xcode-lifecycle-smoke
```

To generate a few real requests and compare metrics before and after:

```sh
scripts/run_metrics_queries.py
```

The first request may take longer while its model downloads and loads.

---

<p align="center">
  Built for fast, local inference on Apple silicon.
</p>
