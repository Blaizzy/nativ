import XCTest
@testable import NativServerKit

final class MCPServerCatalogTests: XCTestCase {
    func testBundledGitHubServerUsesOAuthWithoutPATSetup() throws {
        let github = try XCTUnwrap(MCPServerCatalog.bundled.entry(id: "github"))

        XCTAssertEqual(github.command, "@bundled/github-mcp-server")
        XCTAssertEqual(github.arguments, ["stdio"])
        XCTAssertTrue(github.requiredEnvironment.isEmpty)
        XCTAssertEqual(github.excludedEnvironment, ["GITHUB_PERSONAL_ACCESS_TOKEN"])
    }

    func testMigrationReplacesLegacyGitHubServerAndRemovesPAT() throws {
        let entry = githubEntry()
        let catalog = try MCPServerCatalog(entries: [entry])
        let id = UUID()
        var servers = [
            MCPServerConfig(
                id: id,
                catalogID: "github",
                name: "GitHub override",
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-github"],
                environment: [
                    "GITHUB_PERSONAL_ACCESS_TOKEN": "secret",
                    "KEEP_ME": "value",
                ],
                isEnabled: false
            )
        ]

        XCTAssertTrue(catalog.migrateConfigurations(in: &servers))
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].id, id)
        XCTAssertEqual(servers[0].catalogID, "github")
        XCTAssertEqual(servers[0].name, "github")
        XCTAssertEqual(servers[0].command, "@bundled/github-mcp-server")
        XCTAssertEqual(servers[0].arguments, ["stdio"])
        XCTAssertEqual(servers[0].environment, ["KEEP_ME": "value"])
        XCTAssertFalse(servers[0].isEnabled)
    }

    func testMigrationAdoptsPreCatalogLegacyGitHubConfiguration() throws {
        let catalog = try MCPServerCatalog(entries: [githubEntry()])
        var servers = [
            MCPServerConfig(
                name: "github",
                command: "npx",
                arguments: ["-y", "@modelcontextprotocol/server-github"]
            )
        ]

        XCTAssertTrue(catalog.migrateConfigurations(in: &servers))
        XCTAssertEqual(servers[0].catalogID, "github")
        XCTAssertEqual(servers[0].command, "@bundled/github-mcp-server")
        XCTAssertEqual(servers[0].arguments, ["stdio"])
    }

    private func githubEntry() -> MCPCatalogEntry {
        MCPCatalogEntry(
            id: "github",
            name: "github",
            summary: "GitHub",
            command: "@bundled/github-mcp-server",
            arguments: ["stdio"],
            excludedEnvironment: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            legacyLaunchConfigurations: [
                .init(
                    command: "npx",
                    arguments: ["-y", "@modelcontextprotocol/server-github"]
                )
            ]
        )
    }
}
