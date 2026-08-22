# Models

The Models page discovers installed MLX models, downloads compatible models from Hugging
Face, inspects capabilities, and selects which model the bundled server loads. Source lives in
[`Sources/Nativ/Features/Models/`](../../Sources/Nativ/Features/Models/).

## Discovery

Installed models are found by scanning the Hugging Face cache plus any additional folders.

- The primary search path resolves from the environment (`HF_HUB_CACHE`, then `HF_HOME`),
  exposed as the `modelSearchPath` setting; extra folders live in `additionalModelSearchPaths`.
- Capabilities are derived per model from its `config.json` (or `model_index.json` for
  diffusion pipelines) — see [`LocalModelDiscovery`](../../Sources/Nativ/Features/Models/LocalModelDiscovery.swift).

## Capabilities

Each model carries a set of capabilities (`LocalModelCapability`):

| Capability | Meaning |
|---|---|
| `text` | Text generation (chat). |
| `vision` | Image understanding. |
| `audio`, `video` | Audio / video understanding. |
| `imageGeneration`, `imageEditing` | Produce / edit images. |
| `speechToText`, `textToSpeech` | Transcription / synthesis. |
| `embeddings` | Vector embeddings. |
| `reasoning` | Emits reasoning output. |
| `tools` | Supports tool calling. |
| `drafter` | Usable as a speculative-decoding draft model. |

Capability determines where a model is offered: chat model pickers use
`isEligibleForLanguageModelPicker` — `text` (and non-image `vision`) models qualify, while
`drafter` and `reranking` models are always excluded. Image, speech, and embedding models are
selected in their own slots.

## Downloading

Compatible models download from Hugging Face
([`HuggingFaceHub`](../../Sources/Nativ/Features/Models/HuggingFaceHub.swift)), with a memory-fit
warning when a model is unlikely to fit in available unified memory. Gated repositories require a
Hugging Face token, set in the Developer page or via `HF_TOKEN`. Sharded downloads verify that
every shard is present before a model counts as installed.

## Roles and preloading

Separate models can be assigned per role and loaded concurrently, memory permitting:

| Setting | Role |
|---|---|
| `languageModelID` | Active chat / generation model. |
| `imageGenerationModelID` | Image generate/edit model. |
| `speechToTextModelID` | Dictation and transcription. |
| `embeddingModelID` | Smart search and embeddings. |

The server preloads the selected language model at startup. A selection whose architecture is
non-generative (for example a text encoder) is not preloaded — the server starts and loads a
model on demand instead ([`NativModel.startServer`](../../Sources/Nativ/NativModel.swift)).
Switching the active model restarts the server against the new selection.

## Per-model configuration

Inference settings are remembered per model, so switching models restores that model's profile.
Tunable settings (in [`NativSettings`](../../Sources/Nativ/NativSettings.swift)):

- Sampling: `temperature`, `topK`, `topP`, `maxTokens`.
- Reasoning: `thinkingBudgetEnabled` / `thinkingBudget`.
- Structured output: `structuredOutputEnabled` with a named JSON schema.
- KV-cache quantization: `kvQuantizationEnabled`, `kvBits`, `quantizedKVStart`.
- Prefix caching: `prefixCachingEnabled` and block sizing.

## Speculative decoding

A draft model can accelerate a larger target model. Enable `speculativeDecodingEnabled` and set
`draftModelID`; the draft must be capability-compatible with the target. Draft kind and block
size are configurable (`draftKind`, `draftBlockSize`). Only `drafter`-eligible models are offered
as drafts, and a mismatched hidden size is flagged as an incompatible target.

Drafters are also listed in the chat composer's model menu, in their own section below the chat
models. Selecting one does not load it as the main model — it enables speculative decoding with
that drafter on its compatible target
([`DrafterTargetResolver`](../../Sources/Nativ/Features/Models/LocalModelDiscovery.swift)): the
current chat model when compatible, otherwise the name-derived pair (for example
`Qwen3.8-27B-MTP-8bit` → `Qwen3.8-27B-8bit`), otherwise the first hidden-size-compatible chat
model. When no compatible target is installed, the menu entry notes that a compatible chat model
is needed and selecting it does nothing.
