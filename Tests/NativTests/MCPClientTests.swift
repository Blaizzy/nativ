import XCTest
@testable import NativServerKit

final class MCPClientTests: XCTestCase {
    func testProcessExitSurfacesStderrStatusAndRedactsSecrets() async {
        let secret = "issue-366-secret"
        let client = makeClient(
            script: "i=0; while [ $i -lt 3000 ]; do echo beginning-$i >&2; i=$((i + 1)); done; echo 'Authorization: Bearer \(secret)' >&2; echo 'Invalid MCP header' >&2; exit 23"
        )
        let start = Date()

        let failure = await connectionFailure(from: client, timeout: 5)

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(failure.message, "MCP server exited before connecting.")
        XCTAssertEqual(failure.details?.contains("Process exited with status 23."), true)
        XCTAssertEqual(failure.details?.contains("Earlier server output was truncated."), true)
        XCTAssertEqual(failure.details?.contains("beginning-0\n"), false)
        XCTAssertEqual(failure.details?.contains("Invalid MCP header"), true)
        XCTAssertEqual(failure.details?.contains("<redacted>"), true)
        XCTAssertNotEqual(failure.details?.contains(secret), true)
    }

    func testConnectionDeadlineStopsStalledHandshake() async {
        let client = makeClient(script: "while IFS= read -r line; do :; done")
        let start = Date()

        let failure = await connectionFailure(from: client, timeout: 0.2)
        let isConnected = await client.isConnected

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(failure.message, "MCP server didn’t connect within 1 second.")
        XCTAssertFalse(isConnected)
    }

    private func makeClient(script: String) -> MCPClient {
        MCPClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: [:]
        )
    }

    private func connectionFailure(
        from client: MCPClient,
        timeout: TimeInterval
    ) async -> MCPConnectionFailure {
        do {
            _ = try await client.connectAndListTools(timeout: timeout)
            XCTFail("Expected the MCP connection to fail")
            await client.disconnect()
            return MCPConnectionFailure(message: "Unexpected success")
        } catch let failure as MCPConnectionFailure {
            await client.disconnect()
            return failure
        } catch {
            XCTFail("Expected MCPConnectionFailure, got \(error)")
            await client.disconnect()
            return MCPConnectionFailure(message: error.localizedDescription)
        }
    }
}

@MainActor
final class MCPProjectFilesystemTests: XCTestCase {
    private var temporaryRoot: URL!
    private var host: MCPHostManager!
    private var config: MCPServerConfig!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-mcp-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let entry = MCPCatalogEntry(
            id: "filesystem", name: "filesystem", summary: "Test filesystem",
            command: "/usr/bin/python3", arguments: ["-u", "-c", Self.serverScript, "."]
        )
        config = entry.makeConfiguration()
        config.environment["TEST_CALL_LOG"] = temporaryRoot.appendingPathComponent("calls").path
        host = MCPHostManager(githubOAuth: nil, catalog: try MCPServerCatalog(entries: [entry]))
        await host.prepare(servers: [config])
        XCTAssertEqual(host.states[config.id], .connected(toolCount: 1))
    }

    override func tearDown() async throws {
        host?.shutdown()
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        if let config, let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let managedDirectory = support.appendingPathComponent("Nativ/MCP")
                .appendingPathComponent(config.id.uuidString.replacingOccurrences(of: "-", with: "_"))
            try? FileManager.default.removeItem(at: managedDirectory)
        }
    }

    func testConcurrentProjectsUseDifferentProcessesAndRelativePaths() async throws {
        let a = try scope("Project A with spaces")
        let b = try scope("Project B")
        let host = try XCTUnwrap(self.host)
        let toolName = self.toolName
        async let first = host.callTool(named: toolName, argumentsJSON: #"{"path":"."}"#, projectScope: a)
        async let second = host.callTool(named: toolName, argumentsJSON: #"{"path":"."}"#, projectScope: b)
        let (aResult, bResult) = try await (first, second)
        let firstInfo = try info(aResult)
        let secondInfo = try info(bResult)
        XCTAssertEqual(firstInfo["root"] as? String, a.rootPath)
        XCTAssertEqual(firstInfo["cwd"] as? String, a.rootPath)
        XCTAssertEqual(secondInfo["root"] as? String, b.rootPath)
        XCTAssertEqual(secondInfo["cwd"] as? String, b.rootPath)
        XCTAssertNotEqual(firstInfo["pid"] as? Int, secondInfo["pid"] as? Int)
        let subsequent = try await host.callTool(named: toolName, argumentsJSON: nil, projectScope: a)
        XCTAssertEqual(try info(subsequent)["root"] as? String, a.rootPath)
        XCTAssertNotEqual(try info(subsequent)["pid"] as? Int, firstInfo["pid"] as? Int)
    }

    func testCrossProjectPathsAndEscapingSymlinksAreDenied() async throws {
        let a = try scope("A")
        let b = try scope("B")
        let link = URL(fileURLWithPath: try XCTUnwrap(a.rootPath)).appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: b.rootPath!))
        for path in [b.rootPath!, "../B", "outside"] {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": path]), as: UTF8.self)
            do {
                _ = try await host.callTool(named: toolName, argumentsJSON: arguments, projectScope: a)
                XCTFail("Expected denial for \(path)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("outside allowed directories"))
            }
        }
    }

    func testDisabledMissingAndChangedProjectScopesAreDenied() async throws {
        let original = try scope("Original")
        let changed = try scope("Changed", id: original.projectID)
        let disabled = ChatToolScope(projectID: original.projectID, projectName: nil,
                                     rootPath: original.rootPath, projectToolsEnabled: false)
        let deleted = ChatToolScope(projectID: original.projectID, projectName: nil,
                                    rootPath: nil, projectToolsEnabled: true)
        for current in [changed, disabled, deleted] {
            do {
                _ = try await host.callTool(named: toolName, argumentsJSON: nil,
                                           projectScope: original, currentProjectScope: { current })
                XCTFail("Expected unavailable project to be denied")
            } catch { }
        }
        XCTAssertTrue(host.toolDefinitions(projectScope: disabled).isEmpty)
        XCTAssertTrue(host.toolDefinitions(projectScope: deleted).isEmpty)
        XCTAssertFalse(host.toolDefinitions(projectScope: original).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: callLog.path))
    }

    func testLegacyCatalogConfigurationUsesCurrentProjectAfterRelocation() async throws {
        config.catalogID = nil
        await host.prepare(servers: [config])
        let original = try scope("Original")
        let relocated = try scope("Relocated", id: original.projectID)
        let result = try await host.callTool(
            named: toolName, argumentsJSON: nil, projectScope: relocated
        )
        XCTAssertEqual(try info(result)["root"] as? String, relocated.rootPath)
    }

    func testScopedClientDoesNotRecreateDirectoryRemovedBeforeLaunch() async throws {
        let project = try scope("Removed")
        let directory = URL(fileURLWithPath: project.rootPath!)
        let base = MCPClient(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
        let client = await base.scopedToDirectory(directory, arguments: ["-c", "exit 1"])
        try FileManager.default.removeItem(at: directory)
        do {
            _ = try await client.connectAndListTools(timeout: 1)
            XCTFail("Expected missing working directory to fail")
        } catch { }
        await client.disconnect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPermissionRevokedDuringStartupDoesNotDispatchTool() async throws {
        let original = try scope("A")
        var checks = 0
        do {
            _ = try await host.callTool(named: toolName, argumentsJSON: nil, projectScope: original,
                                       currentProjectScope: {
                checks += 1
                return ChatToolScope(projectID: original.projectID, projectName: nil,
                                     rootPath: original.rootPath, projectToolsEnabled: checks == 1)
            })
            XCTFail("Expected permission revocation to prevent dispatch")
        } catch { }
        XCTAssertEqual(checks, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: callLog.path))
    }

    func testDeletedRootIsNotRecreatedAndRetargetedSymlinkIsRejected() async throws {
        let original = try scope("Original")
        let other = try scope("Other")
        let root = URL(fileURLWithPath: original.rootPath!)
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try MCPHostManager.projectDirectory(expected: original, current: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: URL(fileURLWithPath: other.rootPath!))
        XCTAssertThrowsError(try MCPHostManager.projectDirectory(expected: original, current: original))
    }

    func testStandaloneAndCustomServersKeepTheirConfiguredDirectories() async throws {
        let project = try scope("Project")
        let standalone = try await host.callTool(named: toolName, argumentsJSON: nil)
        let globalRoot = try XCTUnwrap(try info(standalone)["root"] as? String)
        XCTAssertNotEqual(globalRoot, project.rootPath)
        let customRoot = try scope("Custom")
        var custom = config!
        custom.catalogID = nil
        custom.arguments[custom.arguments.count - 1] = customRoot.rootPath!
        await host.prepare(servers: [custom])
        let arguments = String(decoding: try JSONSerialization.data(
            withJSONObject: ["path": customRoot.rootPath!]
        ), as: UTF8.self)
        let customResult = try await host.callTool(
            named: toolName, argumentsJSON: arguments, projectScope: project
        )
        XCTAssertEqual(try info(customResult)["root"] as? String, customRoot.rootPath)
        XCTAssertFalse(host.toolDefinitions(projectScope: ChatToolScope(
            projectID: project.projectID, projectName: nil, rootPath: nil, projectToolsEnabled: false
        )).isEmpty)
    }

    func testDisablingServerDuringStartupPreventsDispatch() async throws {
        let project = try scope("Project")
        var checks = 0
        do {
            _ = try await host.callTool(named: toolName, argumentsJSON: nil, projectScope: project,
                                       currentProjectScope: { [self] in
                checks += 1
                if checks == 1 {
                    var disabled = config!
                    disabled.isEnabled = false
                    host.reload(servers: [disabled])
                }
                return project
            })
            XCTFail("Expected disabled server to reject the call")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: callLog.path))
    }

    func testCancellationClosesScopedProcessAndKeepsSharedConnection() async throws {
        let project = try scope("Project")
        let task = Task { [self] in
            try await host.callTool(named: toolName, argumentsJSON: #"{"hold":true}"#, projectScope: project)
        }
        let pid = try await waitForCall()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancelled call to fail")
        } catch { }
        try await assertProcessExited(pid)
        XCTAssertEqual(host.states[config.id], .connected(toolCount: 1))
    }

    func testShutdownClosesScopedProcess() async throws {
        let project = try scope("Project")
        let task = Task { [self] in
            try await host.callTool(named: toolName, argumentsJSON: #"{"hold":true}"#, projectScope: project)
        }
        let pid = try await waitForCall()
        host.shutdown()
        do {
            _ = try await task.value
            XCTFail("Expected shutdown to fail the pending call")
        } catch { }
        try await assertProcessExited(pid)
        XCTAssertTrue(host.toolDefinitions().isEmpty)
    }

    private var toolName: String { "mcp__filesystem__probe" }
    private var callLog: URL { temporaryRoot.appendingPathComponent("calls") }

    private func scope(_ name: String, id: UUID? = nil) throws -> ChatToolScope {
        let directory = temporaryRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ChatToolScope(projectID: id ?? UUID(), projectName: name,
                             rootPath: directory.path, projectToolsEnabled: true)
    }

    private func info(_ text: String) throws -> [String: Any] {
        var result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        // Python realpath uses /private/var; Foundation canonicalizes it to /var.
        for key in ["root", "cwd"] {
            if let path = result[key] as? String {
                result[key] = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }
        return result
    }

    private func waitForCall() async throws -> Int32 {
        for _ in 0..<200 {
            if let text = try? String(contentsOf: callLog, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Tool did not start")
        throw MCPClientError.timedOut
    }

    private func assertProcessExited(_ pid: Int32) async throws {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scoped process \(pid) is still running")
    }

    // A real stdio MCP process: reports its launch root, cwd and PID, and enforces
    // that root. No npm downloads or external services are needed by these tests.
    private static let serverScript = #"""
    import json, os, pathlib, sys, time
    root = pathlib.Path(sys.argv[1]).resolve()
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request:
            continue
        method = request['method']
        if method == 'initialize':
            result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'probe', 'description': 'Probe filesystem scope', 'inputSchema': {'type': 'object'}}]}
        elif method == 'tools/call':
            pathlib.Path(os.environ['TEST_CALL_LOG']).write_text(str(os.getpid()))
            args = request['params'].get('arguments', {})
            if args.get('hold'):
                time.sleep(30)
            path = pathlib.Path(args.get('path', '.')).resolve()
            denied = path != root and root not in path.parents
            text = 'Access denied - path outside allowed directories' if denied else json.dumps({'root': str(root), 'cwd': os.getcwd(), 'pid': os.getpid()})
            result = {'content': [{'type': 'text', 'text': text}], 'isError': denied}
        else:
            result = {}
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
    """#
}
