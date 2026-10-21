# Contributing an MCP server to the catalog

The **Built in** section on Nativ's MCP page lists the community MCP servers
we've reviewed and shipped. Every server in it is one entry in
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
| `requiresFolder` | no | `true` if the server takes its allowed root folder as a trailing argument. Leave the folder out of `args`: Nativ supplies the project folder in project chats or the authorized folder in standalone chats. CI appends a temp dir. |
| `symbol` | no | SF Symbol shown until a logo asset exists (default `server.rack`). |
| `tint` | no | Card tint: `blue`, `orange`, `teal`, `purple`, `green`, `red`, `pink`, `yellow`, `indigo`, `mint`, `primary`. |
| `sourceURL` | no | Link to the server's source. |

> **Pin Python servers.** A `uvx` server resolves its own dependencies at launch,
> so a new MCP SDK release can break an older server. Pin it in `args` — e.g.
> `["--with", "mcp==1.12.0", "mcp-server-fetch"]` — so both the app and CI launch
> a known-good combination.

### CI-only fields

The bundled filesystem tools execute through Nativ's guarded file I/O. Standalone
reads use **File Read** and mutations use **File Write**; project chats use the
project folder for both. A read-only folder supports reads. Protected instruction
files require the same confirmation as native writes. Directory listings and
recursive searches exclude protected paths and symlinks, and unknown filesystem
tools remain unavailable until Nativ implements their access policy. Editing a
server's command or arguments opts out of this integration; Nativ preserves the
custom launch arguments without adding a folder.

These are read by the verifier, not the app:

| Field | Notes |
|---|---|
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
