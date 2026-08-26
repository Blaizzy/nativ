# Authoring a Kit

A **Kit** is a ready-made setup — a curated bundle of MCP servers, their tools,
skills, and extensions for a role or use-case. Engineering and Research are
built-in examples, not special cases the rest of the implementation depends on.
Applying a Kit additively enables its missing components; each component stays
individually manageable afterward.

Kits are the layer above the [MCP catalog](mcp-catalog.md): the catalog is the
parts bin, a Kit is an assembled machine. Built-in Kits live in code so their
skill text stays readable and type-checked. The validated registry is
[`Sources/Nativ/Features/Extensions/NativKit.swift`](../../Sources/Nativ/Features/Extensions/NativKit.swift).

## The component format

Every Kit uses one ordered `components` array. This is the canonical addition
format and gives every component a stable, typed identity.

| Piece | Component value |
|---|---|
| **MCP servers** (and their tools) | `.mcpServer(catalogID:)` — the stable `id` of a [catalog](mcp-catalog.md) entry. |
| **Skills** | `.skill(...)` — a `NativSkill` defined inline with a stable UUID. |
| **Extensions** | `.extensionPackage(id:)` — a stable extension manifest `id`. |

## Add to an existing kit

Whenever you add a new MCP server to the catalog, a new skill, or a new
extension, you can fold it into a Kit's `components` array:

```swift
components: [
    .mcpServer(catalogID: "your-new-server"),
    .skill(.kit("<new-uuid>", "Your skill", "…")),
    .extensionPackage(id: "com.nativ.your-extension"),
],
```

## Create a new kit

Append a definition to `NativKit.bundledDefinitions`:

```swift
NativKit(
    id: "finance",
    name: "Finance",
    summary: "Pull filings, keep a working memory, and query the numbers.",
    symbol: "dollarsign.circle",
    tintName: "green",
    components: [
        .mcpServer(catalogID: "fetch"),
        .mcpServer(catalogID: "memory"),
        .mcpServer(catalogID: "sqlite"),
        .skill(
            .kit(
                "B1000000-0000-4000-8000-000000000010",
                "Financial analysis",
                """
                You're helping with finance. Ground every figure in a source or the \
                user's own data, and never invent numbers.
                …
                """
            )
        ),
    ]
)
```

Rules of thumb:

- **`id`** is unique, lowercase, and stable. A Kit's Enabled/Partial state is
  derived live from whether its pieces are on, so it never drifts out of sync.
- **MCP catalog IDs** must match catalog entry `id`s. If your Kit needs a server
  that isn't in the catalog yet, add it there first — it has to pass the
  [`Verify MCP Catalog`](../../.github/workflows/verify-mcp-catalog.yml) check.
- **Skill UUIDs** must be stable and unique, so enabling a kit twice never
  duplicates a skill. Generate one and keep it.
- **`tintName`** uses the shared names (`blue`, `green`, `indigo`, `teal`, `purple`,
  …); `symbol` is any SF Symbol.

The catalog rejects duplicate Kit IDs, duplicate components, conflicting skill
UUIDs, and unknown MCP catalog IDs. A valid definition shows up automatically
wherever Kits are offered; no consumer-specific wiring is needed.

Kits never own global capability state. Applying a Kit only enables missing
components. Removing or disabling a shared component remains an explicit action
in that component's own management surface.
