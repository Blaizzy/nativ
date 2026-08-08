import ArgumentParser
import Foundation

/// A single, dense, self-contained reference intended to be piped into a coding
/// agent's context (`nativ agent`) so it can drive the CLI without guessing.
struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Print a complete reference for coding agents (commands, config, API, examples)."
    )

    @Flag(name: .long, help: "Emit the reference as JSON instead of Markdown.") var json = false

    func run() async throws {
        if json {
            print(Self.jsonReference)
        } else {
            print(Self.markdownReference)
        }
    }

    static let markdownReference = """
    # nativ CLI — agent reference (v\(Nativ.version))

    `nativ` is a local, offline command-line client for the Nativ / mlx-vlm
    server (an OpenAI-compatible HTTP API on your machine). It never calls the
    cloud. Use it to chat, generate, embed, transcribe, and manage models.

    ## Invocation
    - `nativ <command> [options]`. With no command, a bare prompt runs `run`:
      `nativ "explain this error"`.
    - `nativ --help`, `nativ help <command>`, and `nativ <command> --help` print usage.
    - Shell completions: `nativ --generate-completion-script zsh` (or bash/fish).
    - Exit code is 0 on success, non-zero on error (message on stderr). Safe to script.

    ## Configuration (resolution order: flag → env → cli.json → default)
    - base URL: `--base-url` | `NATIV_BASE_URL` | cli.json | `http://127.0.0.1:8080`
    - api key:  `--api-key`  | `NATIV_API_KEY`  | cli.json | (none)
    - chat/VLM model:  `--model` | `NATIV_MODEL`           | cli.json.defaultModel
    - embedding model: `--model` | `NATIV_EMBEDDING_MODEL` | cli.json.embeddingModel → falls back to the chat model
    - image model:     `--model` | `NATIV_IMAGE_MODEL`     | cli.json.imageModel → falls back to the chat model
    - stt model:       `--model` | `NATIV_STT_MODEL`       | cli.json.sttModel → falls back to the chat model
    - tts model:       `--model` | `NATIV_TTS_MODEL`       | cli.json.ttsModel → falls back to the chat model
    - model search path: `NATIV_MODEL_PATH` | cli.json.modelSearchPath
    - server binary override: `NATIV_SERVER_BIN`
    cli.json lives at `~/Library/Application Support/Nativ/cli.json`.
    Inspect with `nativ config show`; write with `nativ config set --model <id> ...`.

    ## Commands
    - `run [prompt]` — one-shot completion, streams to stdout.
      `--model`, `--system <text>`, `--image <path>` (repeatable, VLM),
      `--no-stream` (buffer then print), `--json` (raw completion JSON, for parsing).
      Reads the prompt from stdin if omitted: `echo "hi" | nativ run`.
    - `chat` — interactive REPL. Slash: `/model <id>`, `/system <text>`, `/reset`,
      `/help`, `/exit`. Triple-double-quote on its own line = multi-line message.
    - `serve [--port N] [--host H] [-d] [-- passthrough...]` — start the bundled
      server. `-d` detaches (logs to Application Support/server.log) and waits
      until the server answers before returning.
    - `status` — is the server up, managed pid, default model, served models.
    - `stop` — stop a `serve`-started server.
    - `models list [--server-only]` — models loaded by the server plus those cached
      locally (search path + Hugging Face hub cache); each tagged loaded/cached.
    - `models use <id>` — set the default chat model in cli.json.
    - `models pull <repo-id>` — download from Hugging Face (needs huggingface-cli).
    - `models rm <id> [-f]` — delete a model from disk (search path or HF cache).
    - `embed [text...]` — embeddings; `--dims` prints only dimensions; else JSON
      array-of-vectors. Reads stdin (one input per line) if no args.
    - `image [prompt...] [--out file] [--size WxH]` — generate an image to a file.
    - `transcribe <audio-file>` — speech-to-text, prints the transcript.
    - `audio speak [text...] [--out file] [--voice v] [--speed s] [--format mp3]` —
      text-to-speech; writes an audio file (reads stdin if no text). The `audio`
      group is where other audio-out tasks land as the server grows endpoints.
    - `config show | set | path` — read/write cli.json.
    - `agent [--json]` — this reference.

    ## Underlying HTTP API (for direct calls if needed)
    - POST `/v1/chat/completions` — {model, messages, stream}. SSE lines `data: {...}`,
      terminated by `data: [DONE]`; text is `choices[0].delta.content`.
    - POST `/v1/embeddings` — {model, input:[...]} → data[].embedding.
    - POST `/v1/images/generations` — {model, prompt, size, response_format:"b64_json"}.
    - POST `/v1/audio/transcriptions` — multipart {model, file} → {text}.
    - POST `/v1/audio/speech` — {model, input, voice, speed, response_format} → audio bytes.
    - GET  `/v1/models` — {data:[{id}]}.
    Auth: `Authorization: Bearer <api-key>` when one is configured.

    ## Recipes
    - Ensure a model, then ask:
      `nativ models use mlx-community/Qwen2.5-VL-7B-Instruct-4bit && nativ "summarize: $(cat notes.txt)"`
    - Describe an image: `nativ run --image shot.png "what's wrong here?"`
    - Parseable output: `nativ run --json "return JSON: {ok:true}" | jq .choices[0].message.content`
    - Start the server for a batch job: `nativ serve -d && nativ status`
    """

    static let jsonReference: String = {
        let obj: [String: Any] = [
            "tool": "nativ",
            "version": Nativ.version,
            "summary": "Local, offline CLI for the Nativ / mlx-vlm OpenAI-compatible server.",
            "configResolution": ["flag", "env", "cli.json", "default"],
            "configFile": "~/Library/Application Support/Nativ/cli.json",
            "env": [
                "NATIV_BASE_URL", "NATIV_API_KEY", "NATIV_MODEL",
                "NATIV_EMBEDDING_MODEL", "NATIV_IMAGE_MODEL", "NATIV_STT_MODEL",
                "NATIV_TTS_MODEL", "NATIV_MODEL_PATH", "NATIV_SERVER_BIN",
            ],
            "commands": [
                ["name": "run", "desc": "one-shot completion (streams)", "flags": ["--model", "--system", "--image", "--no-stream", "--json"]],
                ["name": "chat", "desc": "interactive REPL", "flags": ["--model", "--system"]],
                ["name": "serve", "desc": "start bundled server", "flags": ["--port", "--host", "-d"]],
                ["name": "status", "desc": "server + model status", "flags": []],
                ["name": "stop", "desc": "stop a serve-started server", "flags": []],
                ["name": "models list", "desc": "loaded + locally cached models", "flags": ["--server-only"]],
                ["name": "models use", "desc": "set default chat model", "flags": []],
                ["name": "models pull", "desc": "download from Hugging Face", "flags": []],
                ["name": "models rm", "desc": "delete model from disk", "flags": ["-f"]],
                ["name": "embed", "desc": "text embeddings", "flags": ["--model", "--dims"]],
                ["name": "image", "desc": "generate an image", "flags": ["--model", "--out", "--size"]],
                ["name": "transcribe", "desc": "speech-to-text", "flags": ["--model"]],
                ["name": "audio speak", "desc": "text-to-speech (audio group grows: separate/enhance/sfx)", "flags": ["--model", "--out", "--voice", "--speed", "--format"]],
                ["name": "config", "desc": "show/set cli.json", "flags": []],
            ],
            "api": [
                "chat": "POST /v1/chat/completions",
                "embeddings": "POST /v1/embeddings",
                "images": "POST /v1/images/generations",
                "transcriptions": "POST /v1/audio/transcriptions",
                "speech": "POST /v1/audio/speech",
                "models": "GET /v1/models",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }()
}
