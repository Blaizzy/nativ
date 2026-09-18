import XCTest
@testable import NativServerKit

final class MCPServerCatalogLiveVerificationTests: XCTestCase {
    private static let bundledPrefix = "@bundled/"
    private static let timeout: TimeInterval = 120

    func testEveryCatalogServerListsTools() async throws {
        guard ProcessInfo.processInfo.environment["NATIV_VERIFY_MCP_CATALOG"] == "1" else {
            throw XCTSkip("Set NATIV_VERIFY_MCP_CATALOG=1 to run live catalog verification.")
        }

        let catalog = MCPServerCatalog.bundled
        XCTAssertFalse(catalog.entries.isEmpty, "MCPCatalog.json failed to load")

        var entries = catalog.entries
        if let only = ProcessInfo.processInfo.environment["NATIV_MCP_VERIFY_ONLY"], !only.isEmpty {
            entries = entries.filter { $0.id == only }
            XCTAssertFalse(entries.isEmpty, "No catalog entry with id '\(only)'")
        }

        let bundledDirectory = ProcessInfo.processInfo.environment["NATIV_BUNDLED_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-mcp-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var rows: [(name: String, status: String, detail: String)] = []
        var failures = 0

        for entry in entries {
            if entry.ciSkip {
                let reason = entry.ciSkipReason ?? "opted out via ciSkip"
                rows.append((entry.name, "skipped", reason))
                print("[skip] \(entry.name): \(reason)")
                continue
            }
            do {
                let count = try await verify(entry, folder: folder, bundledDirectory: bundledDirectory)
                guard count > 0 else {
                    throw MCPConnectionFailure(message: "connected but exposed no tools")
                }
                rows.append((entry.name, "pass", "\(count) tool(s)"))
                print("[ok] \(entry.name): \(count) tool(s)")
            } catch {
                failures += 1
                rows.append((entry.name, "FAIL", "\(type(of: error)): \(error)"))
                print("[FAIL] \(entry.name): \(error)")
            }
        }

        writeGitHubStepSummary(rows)
        XCTAssertEqual(failures, 0, "\(failures) catalog server(s) failed verification")
    }

    private func verify(
        _ entry: MCPCatalogEntry,
        folder: URL,
        bundledDirectory: URL?
    ) async throws -> Int {
        var arguments = entry.arguments
        if entry.requiresFolder {
            arguments.append(folder.path)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in entry.excludedEnvironment {
            environment.removeValue(forKey: key)
        }
        for key in entry.requiredEnvironment + entry.verificationEnvironment {
            environment[key] = environment[key] ?? "ci-placeholder-value"
        }

        let (executableURL, resolvedArgs) = try resolveLaunch(
            command: entry.command,
            arguments: arguments,
            bundledDirectory: bundledDirectory
        )
        let client = MCPClient(
            executableURL: executableURL,
            arguments: resolvedArgs,
            environment: environment,
            workingDirectory: folder
        )
        do {
            let tools = try await client.connectAndListTools(timeout: Self.timeout)
            await client.disconnect()
            return tools.count
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func resolveLaunch(
        command: String,
        arguments: [String],
        bundledDirectory: URL?
    ) throws -> (URL, [String]) {
        if command.hasPrefix(Self.bundledPrefix) {
            let name = String(command.dropFirst(Self.bundledPrefix.count))
            guard !name.isEmpty, !name.contains("/"),
                let bundledDirectory,
                FileManager.default.isExecutableFile(
                    atPath: bundledDirectory.appendingPathComponent(name).path
                )
            else {
                throw MCPConnectionFailure(message: "bundled executable not found: \(command)")
            }
            return (bundledDirectory.appendingPathComponent(name), arguments)
        }
        if command.hasPrefix("/") {
            return (URL(fileURLWithPath: command), arguments)
        }
        return (
            URL(fileURLWithPath: "/usr/bin/env"),
            [command] + arguments
        )
    }

    private func writeGitHubStepSummary(_ rows: [(name: String, status: String, detail: String)]) {
        guard let summaryPath = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"] else {
            return
        }
        var lines = ["| Server | Result | Detail |", "|---|---|---|"]
        lines += rows.map { "| \($0.name) | \($0.status) | \($0.detail) |" }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: summaryPath),
            let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: summaryPath))
        {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: summaryPath))
        }
    }
}
