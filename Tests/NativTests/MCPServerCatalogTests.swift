import AppKit
import SwiftUI
import XCTest
@testable import NativServerKit

final class MCPServerCatalogTests: XCTestCase {
    func testBundledCatalogLoadsEveryEntry() throws {
        XCTAssertFalse(MCPServerCatalog.bundled.entries.isEmpty)
        XCTAssertEqual(MCPServerCatalog.bundled.entries.count, try rawCatalogEntries().count)
    }

    func testCatalogEntriesUseOnlyKnownFields() throws {
        let appFields: Set = [
            "id", "name", "summary", "command", "args", "symbol", "tint", "sourceURL",
            "requiredEnv", "excludedEnv", "legacyLaunchConfigurations",
        ]
        let verifierFields: Set = ["requiresFolder", "verificationEnv", "ciSkip", "ciSkipReason"]
        for entry in try rawCatalogEntries() {
            let unknown = Set(entry.keys).subtracting(appFields).subtracting(verifierFields)
            XCTAssertTrue(unknown.isEmpty, "\(entry["id"] ?? "?") has unknown fields \(unknown.sorted())")
        }
    }

    func testCatalogEntriesAreWellFormed() {
        for entry in MCPServerCatalog.bundled.entries {
            XCTAssertNotNil(entry.id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/), "\(entry.id) id")
            for (field, value) in [("name", entry.name), ("summary", entry.summary), ("command", entry.command)] {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id) \(field)")
            }
            XCTAssertFalse(entry.summary.contains("\n"), "\(entry.id) summary must be one line")
            XCTAssertNotNil(
                NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil),
                "\(entry.id) symbol \(entry.symbol) is not an SF Symbol"
            )
            XCTAssertNotEqual(
                Color.nativTint(entry.tintName),
                .accentColor,
                "\(entry.id) tint \(entry.tintName) is not a supported tint"
            )
            if let sourceURL = entry.sourceURL {
                let url = URL(string: sourceURL)
                XCTAssertEqual(url?.scheme, "https", "\(entry.id) sourceURL")
                XCTAssertNotNil(url?.host(), "\(entry.id) sourceURL")
            }
            if entry.command == "uvx" {
                XCTAssertTrue(
                    entry.arguments.contains { $0.hasPrefix("mcp==") },
                    "\(entry.id) must pin the MCP SDK, e.g. --with mcp==1.12.0"
                )
            }
        }
    }

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

    private func rawCatalogEntries() throws -> [[String: Any]] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "MCPCatalog", withExtension: "json")
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [[String: Any]])
    }
}

final class MCPLaunchCommandTests: XCTestCase {
    func testParsesSingleExecutablePath() throws {
        let launchCommand = try MCPLaunchCommand(
            parsing: "/Applications/Humla.app/Contents/MacOS/humla-mcp"
        )

        XCTAssertEqual(
            launchCommand.executable,
            "/Applications/Humla.app/Contents/MacOS/humla-mcp"
        )
        XCTAssertEqual(launchCommand.arguments, [])
        XCTAssertEqual(launchCommand.suggestedName, "humla-mcp")
    }

    func testParsesQuotedExecutableAndArguments() throws {
        let launchCommand = try MCPLaunchCommand(
            parsing: #""/Applications/My MCP/server" --label "Team Notes" --empty """#
        )

        XCTAssertEqual(launchCommand.executable, "/Applications/My MCP/server")
        XCTAssertEqual(
            launchCommand.arguments,
            ["--label", "Team Notes", "--empty", ""]
        )
    }

    func testRenderedCommandRoundTripsWithoutLosingWords() throws {
        let original = MCPLaunchCommand(
            executable: "/Applications/My MCP/server",
            arguments: ["plain", "a user's notes", #"quote\"and\\slash"#, ""]
        )

        XCTAssertEqual(try MCPLaunchCommand(parsing: original.rendered), original)
    }

    func testRejectsEmptyAndUnfinishedCommands() {
        XCTAssertThrowsError(try MCPLaunchCommand(parsing: "   ")) { error in
            XCTAssertEqual(error as? MCPLaunchCommandError, .empty)
        }
        XCTAssertThrowsError(try MCPLaunchCommand(parsing: #"server "unfinished"#)) { error in
            XCTAssertEqual(error as? MCPLaunchCommandError, .unfinishedQuoteOrEscape)
        }
    }
}
