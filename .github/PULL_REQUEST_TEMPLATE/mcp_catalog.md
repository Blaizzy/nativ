## MCP server

- **Server:** <!-- name and one line on what it does -->
- **Source:** <!-- link to the server's repository -->
- **Package:** <!-- npm or PyPI package and the pinned version -->

## Checklist

- [ ] Added one entry to `Sources/Nativ/Resources/MCPCatalog.json` following [the catalog guide](../../Docs/extending/mcp-catalog.md).
- [ ] The `id` is unique, lowercase, and hyphenated.
- [ ] The package version is pinned in `args`; `uvx` servers also pin the MCP SDK (`--with mcp==<version>`).
- [ ] Every environment variable the server needs to start is listed in `requiredEnv`.
- [ ] `python scripts/verify_mcp_catalog.py --only <id>` lists at least one tool.
- [ ] `MCPServerCatalogTests` pass.
- [ ] Every commit is signed.

## Notes for reviewers

<!-- Accounts, API keys, or local apps the server depends on, and anything CI cannot check (for example, why `ciSkip` is set). -->
