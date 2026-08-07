# Authoring a Kit

A **Kit** is a ready-made setup — a curated bundle of MCP servers, their tools,
skills, and extensions for a role or use-case (Engineering, Research, Sales,
Operations…). Enabling a kit turns all of its pieces on at once; each piece
stays individually manageable afterward.

Kits are the layer above the [MCP catalog](mcp-catalog.md): the catalog is the
parts bin, a kit is an assembled machine. Kits live in code so their skill text
stays readable and type-checked. The registry is
[`Sources/Nativ/Features/Extensions/NativKit.swift`](../Sources/Nativ/Features/Extensions/NativKit.swift).

## The four things a kit can bundle

| Piece | How the kit references it |
|---|---|
| **MCP servers** (and their tools) | `mcpServerIDs` — the `id` of a [catalog](mcp-catalog.md) entry. Enabling the kit installs the server if missing; its tools then appear under **Tools**. |
| **Skills** | `skills` — `NativSkill` values defined inline, each with a stable UUID. |
| **Extensions** | `extensionIDs` — an extension manifest `id` (e.g. `com.nativ.voice-dictation`). |

## Add to an existing kit

Whenever you add a new MCP server to the catalog, a new skill, or a new
extension, you can fold it into a kit by editing that kit in `NativKit.all`:

```swift
mcpServerIDs: ["git", "github", "filesystem", "fetch", "your-new-server"],
extensionIDs: ["com.nativ.your-extension"],
skills: [ existingSkill, .kit("<new-uuid>", "Your skill", "…") ],
```

## Create a new kit

Append an entry to `NativKit.all`:

```swift
NativKit(
    id: "finance",
    name: "Finance",
    summary: "Pull filings, keep a working memory, and query the numbers.",
    symbol: "dollarsign.circle",
    tint: .green,
    mcpServerIDs: ["fetch", "memory", "sqlite"],
    extensionIDs: [],
    skills: [
        .kit(
            "B1000000-0000-4000-8000-000000000010",
            "Financial analysis",
            """
            You're helping with finance. Ground every figure in a source or the \
            user's own data, and never invent numbers.
            …
            """
        )
    ]
)
```

Rules of thumb:

- **`id`** is unique, lowercase, and stable. A kit's Enabled/Partial state is
  derived live from whether its pieces are on, so it never drifts out of sync.
- **`mcpServerIDs`** must match catalog entry `id`s. If your kit needs a server
  that isn't in the catalog yet, add it there first — it has to pass the
  [`Verify MCP Catalog`](../.github/workflows/verify-mcp-catalog.yml) check.
- **Skill UUIDs** must be stable and unique, so enabling a kit twice never
  duplicates a skill. Generate one and keep it.
- **`tint`** uses the shared names (`blue`, `green`, `indigo`, `teal`, `purple`,
  …); `symbol` is any SF Symbol.

A new kit shows up automatically as a card at the top of the Extensions hub —
no other wiring needed.
