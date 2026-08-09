# Contributing an MCP server to the catalog

The **Browse catalog** grid in Nativ's MCP section is the list of community MCP
servers we've reviewed and shipped. Every server in it is one entry in
[`Sources/Nativ/Resources/MCPCatalog.json`](../../Sources/Nativ/Resources/MCPCatalog.json),
and every entry has to pass CI before it can merge — the
[`Verify MCP Catalog`](../../.github/workflows/verify-mcp-catalog.yml) workflow
launches your server over stdio, completes an MCP `initialize` handshake, calls
`tools/list`, and requires **at least one tool** to come back.

## Add an entry

Append an object to `MCPCatalog.json`:

```json
{
  "id": "fetch",
  "name": "fetch",
  "summary": "Fetch and read web pages as markdown.",
  "command": "uvx",
  "args": ["mcp-server-fetch"],
  "symbol": "globe",
  "tint": "teal",
  "sourceURL": "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch"
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Unique, lowercase, stable. |
| `name` | yes | Shown on the card and used to launch the server. |
| `summary` | yes | One line describing what the server does. |
| `command` | yes | The stdio launcher — usually `npx`, `uvx`, or a binary. |
| `args` | yes | Arguments passed to `command`. |
| `symbol` | no | SF Symbol shown until a logo asset exists (default `server.rack`). |
| `tint` | no | Card tint: `blue`, `orange`, `teal`, `purple`, `green`, `red`, `pink`, `yellow`, `indigo`, `mint`, `primary`. |
| `sourceURL` | no | Link to the server's source. |

> **Pin Python servers.** A `uvx` server resolves its own dependencies at launch,
> so a new MCP SDK release can break an older server. Pin it in `args` — e.g.
> `["--with", "mcp==1.12.0", "mcp-server-fetch"]` — so both the app and CI launch
> a known-good combination.

### CI-only fields

These are read by the verifier, not the app:

| Field | Notes |
|---|---|
| `requiresFolder` | `true` if the server takes a working directory as its last argument — CI appends a temp dir. |
| `requiredEnv` | Env var names the server needs to start; CI supplies placeholder values (a healthy server lists its tools without valid credentials). |
| `ciSkip` | `true` to opt out of the live check (last resort). |
| `ciSkipReason` | Why the entry is skipped. |

## Add a logo (optional)

Drop a square image into `Assets.xcassets` as `MCPLogo-<name>` (matching the
entry's `name`). Without one, the card shows the tinted `symbol` tile.

## Run the check locally

```sh
pip install "mcp>=1.0"
python scripts/verify_mcp_catalog.py            # all entries
python scripts/verify_mcp_catalog.py --only fetch
```
