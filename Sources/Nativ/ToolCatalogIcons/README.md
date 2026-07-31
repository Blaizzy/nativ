# Tool catalog icons

Logo images for MCP servers listed in [`../Resources/ToolCatalog.json`](../Resources/ToolCatalog.json).

Each catalog entry with a `logo` field loads the matching file from this folder, which ships inside the app bundle. Name the file after the value you put in `logo` (for example `logo: "github.png"` loads `github.png` here).

Guidelines:

- Square image, PNG or SVG, at least 128×128.
- Use the server or tool's own logo (e.g. the GitHub mark for a GitHub server).
- Keep the file small; trim transparent padding.

See [`../../../CONTRIBUTING.md`](../../../CONTRIBUTING.md) for the full catalog entry format.
