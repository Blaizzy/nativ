# Contributing

## Adding an MCP server to the Tools catalog

Nativ's **Tools** page lets people connect [Model Context Protocol](https://modelcontextprotocol.io) servers so their local models can call external tools. The **Catalog** is a curated list of servers anyone can one-click enable — and you can add to it with a small pull request.

### How to contribute

Add one JSON object to [`Sources/Nativ/Resources/ToolCatalog.json`](Sources/Nativ/Resources/ToolCatalog.json) and open a PR. That's it — no Swift, no build changes.

```json
{
  "id": "github",
  "name": "GitHub",
  "description": "Search repositories, issues, and pull requests.",
  "category": "Development",
  "icon": "chevron.left.forwardslash.chevron.right",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-github"],
  "requiredEnv": ["GITHUB_PERSONAL_ACCESS_TOKEN"],
  "sourceURL": "https://github.com/github/github-mcp-server"
}
```

### Fields

| Field | Required | Description |
|---|---|---|
| `id` | yes | Unique, stable slug for the entry (lowercase, `a–z0–9-`). |
| `name` | yes | Display name. |
| `description` | yes | One sentence describing what the server does. |
| `command` | yes | The launcher, e.g. `npx`, `uvx`, or an absolute path to a binary. |
| `args` | yes | Arguments passed to `command` (e.g. `["-y", "@scope/server"]`). |
| `category` | no | Grouping label (defaults to `Other`). |
| `icon` | no | An [SF Symbol](https://developer.apple.com/sf-symbols/) name (defaults to `wrench.and.screwdriver`). |
| `requiredEnv` | no | Environment variables the user must supply (tokens, keys). Nativ prompts for these when the server is added and stores them locally — **never commit secrets**. |
| `requiresFolder` | no | If `true`, Nativ shows a folder picker and appends the chosen path to `args` (e.g. a filesystem root). |
| `sourceURL` | no | Link to the server's homepage or repository. |

### Rules

- **Launch-only.** An entry may *only launch* an MCP server via `command` + `args`. Nativ intentionally does **not** support install, bootstrap, or setup steps — no `git clone`, no `pip install` / `npm install`, no build scripts, and no post-install commands run on the user's machine. Servers that need a separate install or manual device setup are out of scope. This is a security boundary: the catalog should never turn a merged PR into arbitrary setup code executed on someone's Mac.
- **Prefer official, well-known servers.** Point `command`/`args` at published packages (e.g. `npx -y <package>`, `uvx <package>`) from reputable sources.
- **Secrets are the user's.** Declare them in `requiredEnv`; never hard-code tokens or keys.
- **Review is approval.** Because an enabled server runs on the user's machine (each tool call still requires the user's in-chat approval), catalog entries are reviewed before merge. Merging an entry vouches for it.

If a server can't be expressed as a plain launch command, it isn't a fit for the catalog today.
