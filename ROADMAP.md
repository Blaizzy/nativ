# Nativ — Roadmap

<!-- Generated from nativ.yml by scripts/render_manifest.py. Do not edit by hand. -->

Committed and exploratory work, rendered from `nativ.yml`. Shipped capabilities are in [SUPPORT_MATRIX.md](SUPPORT_MATRIX.md).

## Experimental

### Custom local server port

Choose the local server port from the Developer page (in progress on feature/custom-server-port; not yet on main).

## Planned

### Dedicated audio models (speech recognition & speech generation) (#15)

Coming soon. API surface (/v1/audio/*) is present; the dedicated audio-model runtime is not yet integrated.

- [ ] Detect audio capabilities; distinguish transcription, translation, and text-to-speech.
- [ ] Discover, download, display, select, load, and unload compatible audio models.
- [ ] Route audio models through a dedicated runtime, not the language/vision path.
- [ ] Serve /v1/audio/transcriptions, /v1/audio/translations, /v1/audio/speech by capability.
- [ ] Handle audio file validation, formats, generated output, cancellation, and errors.
- [ ] Add audio request and performance data to analytics.

### Dedicated embedding models (#16)

Not yet supported. Requires bundling mlx-embeddings and a dedicated embedding runtime.

- [ ] Detect embedding capabilities from local and Hugging Face metadata.
- [ ] Keep embedding models out of language-model selection; show them in the library with the correct type.
- [ ] Add a dedicated load/unload runtime path for embedding models.
- [ ] Implement OpenAI-compatible POST /v1/embeddings (string or array -> vectors, metadata, usage).
- [ ] Surface model state, load failures, and unsupported architectures in app and logs.
- [ ] Track embedding requests in analytics without assuming generated-token metrics.

### Dedicated image-generation models (#14 #44 #46)

Coming soon. /v1/images/* routes and the ImageGeneration workspace are scaffolded; the dedicated diffusion runtime and memory-aware fit estimate are not yet complete.

- [ ] Detect image-generation models from local and Hugging Face metadata.
- [ ] Discover, download, display, select, load, and unload compatible models.
- [ ] Add a dedicated image-generation runtime, not the language/vision path.
- [ ] Implement OpenAI-compatible POST /v1/images/generations (prompt, size, seed, step, output format).
- [ ] Wire the workspace: progress, cancellation, previews, and save/export.
- [ ] Report load failures, generation failures, and unsupported parameters.
- [ ] Track image-generation requests and timing in analytics.
- [ ] Make the memory fit estimate activation-aware for diffusion (peak reserve, not weights-only). [#46]

### Gated Hugging Face model downloads (#23)

Authenticate with Hugging Face to download license-gated / access-requested models from within Nativ.

### Model metadata in /v1/models (context window, tools, vision) (#56)

Expose per-model max context window and tool/function-calling and vision support in /v1/models so OpenAI-compatible clients (e.g. the community VSCode extension) need not hardcode them.

- [ ] Add max context window / max output tokens to each /v1/models entry.
- [ ] Advertise tool / function-calling support per model in /v1/models.
- [ ] Advertise vision (image input) support per model in /v1/models.
- [ ] Verify OpenAI-compatible tool calling end-to-end so the VSCode 'Agent' mode works.

## Backlog by area

### app

- [#11](https://github.com/Blaizzy/nativ/issues/11) UI gets crunchy and stops updating unless fed input events
- [#23](https://github.com/Blaizzy/nativ/issues/23) Support downloading gated Hugging Face models
- [#26](https://github.com/Blaizzy/nativ/issues/26) Reduce and document the Nativ app bundle footprint
- [#46](https://github.com/Blaizzy/nativ/issues/46) Image-gen fit estimate is weights-only and misleads for diffusion _( part of #44; depends on #14 )_

### docs

- [#27](https://github.com/Blaizzy/nativ/issues/27) Publish reproducible MLX performance benchmarks by Apple chip generation
- [#29](https://github.com/Blaizzy/nativ/issues/29) Create a Mac hardware, model, and local-use-case guide
- [#31](https://github.com/Blaizzy/nativ/issues/31) Add a public roadmap, changelog, and feature support matrix

### platform

- [#24](https://github.com/Blaizzy/nativ/issues/24) Support macOS Sequoia by lowering the deployment target
- [#30](https://github.com/Blaizzy/nativ/issues/30) Explore an iPad and iPhone version of Nativ

### runtime

- [#4](https://github.com/Blaizzy/nativ/issues/4) Models fail to load with "Model type not supported"
- [#14](https://github.com/Blaizzy/nativ/issues/14) Support image generation models
- [#15](https://github.com/Blaizzy/nativ/issues/15) Support audio models
- [#16](https://github.com/Blaizzy/nativ/issues/16) Support embedding models
- [#22](https://github.com/Blaizzy/nativ/issues/22) Add support for Core AI and Apple Foundation Models
- [#28](https://github.com/Blaizzy/nativ/issues/28) Evaluate DS4 as a backend for DeepSeek V4 Flash
- [#44](https://github.com/Blaizzy/nativ/issues/44) Image-generation model support: memory-architecture suggestions & gotchas _( includes #46 )_

### server

- [#13](https://github.com/Blaizzy/nativ/issues/13) 405 when messaging in chat
- [#56](https://github.com/Blaizzy/nativ/issues/56) /v1/models data - VSCode extension (Language Model Chat Provider)

### website

- [#32](https://github.com/Blaizzy/nativ/issues/32) Rewrite the landing page with concrete, unambiguous product messaging
- [#34](https://github.com/Blaizzy/nativ/issues/34) Fix landing-page overflow and responsive mobile layout
- [#35](https://github.com/Blaizzy/nativ/issues/35) Replace the contradictory "Universal · Apple Silicon" platform label
