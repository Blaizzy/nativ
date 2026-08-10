# Chat

Chat is the primary workspace for conversing with a locally served model. It streams
responses, renders reasoning output, accepts image attachments for vision models, and
exposes host capabilities to the model as consent-gated tools. Source lives in
[`Sources/Nativ/Features/Chat/`](../../Sources/Nativ/Features/Chat/).

## Conversations

- Responses stream token by token. Reasoning ("thinking") output from models that emit
  it renders in a collapsible panel separate from the final answer.
- Per-response metrics (time to first token, decode speed, token counts) are recorded and
  surfaced from the analytics store.
- Image attachments accompany a user message for vision-capable models.
- The active model is chosen from the model picker; only language-capable models are
  selectable as the conversation model.

## Sessions and folders

Each conversation is one session, persisted as a JSON file under
`~/Library/Application Support/Nativ/` and loaded on launch
([`ChatSessionStore`](../../Sources/Nativ/Features/Chat/ChatSessionStore.swift)). A session
carries its title, messages, timestamps, pin state, and an optional folder assignment.

- Sessions can be renamed, pinned, and deleted from the sidebar.
- Folders (`ChatFolder`) group sessions in the sidebar; folder membership is stored on the
  session (`folderID`) and the folder list persists alongside sessions.
- Empty, redundant sessions are pruned automatically.

## Chat tools

A tool-calling model can invoke host capabilities mid-conversation. The registry is
[`ChatToolRegistry`](../../Sources/Nativ/Features/Chat/ChatToolRegistry.swift); available tools:

| Tool | Action |
|---|---|
| Image generate / edit | Produce or edit an image with a compatible image model. |
| Model library | List installed models or switch the active model. |
| Server stats | Report server and request statistics. |
| System monitor | Report live CPU, GPU, and memory readings. |

Tools are advertised to the model only when the active model reports tool-calling support
and the tool is enabled. Each invocation passes through a consent gate
(`ChatToolConsentGate`) before it runs, so a tool call surfaces a prompt rather than
executing silently. MCP servers contribute additional tools through the same path — see
[Integrations](integrations.md).

## Image generation

Two paths produce images:

- **Direct** — the **Images** tab drives an image model on its own, with no language model
  involved. Prompt text feeds the image model's own text encoder. Source:
  [`Sources/Nativ/Features/ImageGeneration/`](../../Sources/Nativ/Features/ImageGeneration/).
- **Indirect** — a tool-calling language model calls the image generate/edit tool during a
  chat. The host resolves which image model to run — from the per-session image model, then
  the global `imageGenerationModelID` setting; when neither resolves and more than one
  compatible model is installed, a selection prompt appears; when none is installed, the tool
  returns an actionable "no compatible model" result. Generation runs on the bundled server's
  image endpoint (see [Developer](developer.md)). Model routing lives in
  [`ChatImageModelSelection`](../../Sources/Nativ/Features/Chat/Tools/ChatImageModelSelection.swift).

`imageGeneration` and `imageEditing` are distinct model capabilities; editing requires a
reference image and a model that supports it. See [Models](models.md) for capabilities.

## Artifacts

Every image and document generated or uploaded across chats is collected in the **Artifacts**
gallery ([`Sources/Nativ/Features/Artifacts/`](../../Sources/Nativ/Features/Artifacts/)). It
supports filtering by kind, source (uploaded vs generated), date, and favorites; sorting; and
grouping by chat. Rendered files are cached under Application Support.

**Smart search** ranks artifacts semantically using an on-device embedding model. It activates
only after that model is installed; until then, search falls back to plain text matching over
artifact metadata.
