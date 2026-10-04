# Contributing to Nativ

Thanks for helping improve Nativ. This page covers what every pull request needs;
the [documentation](Docs/README.md) explains how each feature works.

## Before you open a pull request

- **Sign every commit.** GitHub must mark each commit as **Verified**. See
  [GitHub's commit-signing guide](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits).
- **Build and test on macOS 26** with Apple silicon and Xcode's macOS 26 SDK:

  ```sh
  brew install xcodegen
  make xcode-build
  xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug \
    -derivedDataPath build/NativDevelopmentDerivedData \
    CODE_SIGNING_ALLOWED=NO NATIV_SKIP_PYTHON_RESOURCE_BUILD=YES test
  ```

  Add `-only-testing:NativTests/<TestClass>` to run one suite.
- **Keep the change focused.** One fix or feature per pull request, with tests for
  new behavior.

CI runs on every pull request. If a check fails, a bot comment lists the commands
to reproduce it locally and says whether the same check is failing on `main`.

## Adding an MCP server to the catalog

The **Built in** MCP list is [`MCPCatalog.json`](Sources/Nativ/Resources/MCPCatalog.json).
Follow [Contributing an MCP server to the catalog](Docs/extending/mcp-catalog.md), then
open your pull request with the
[MCP catalog template](https://github.com/Blaizzy/nativ/compare?expand=1&template=mcp_catalog.md).

## Other extension points

- [Extensions](Docs/extending/extensions.md) — the extension package format and lifecycle.
- [Kits](Docs/extending/kits.md) — curated bundles of MCP servers, skills, and extensions.
