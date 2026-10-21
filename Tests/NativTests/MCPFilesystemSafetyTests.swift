import NativServerKit
import XCTest

@MainActor
final class MCPFilesystemSafetyTests: XCTestCase {
    private var directory: URL!
    private var readRoot: URL!
    private var writeRoot: URL!
    private var host: MCPHostManager!
    private var config: MCPServerConfig!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-filesystem-safety-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        readRoot = directory.appendingPathComponent("read")
        writeRoot = directory.appendingPathComponent("write")
        for url in [readRoot!, writeRoot!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let entry = MCPCatalogEntry(
            id: "filesystem", name: "filesystem", summary: "Filesystem fixture",
            command: "/usr/bin/python3", arguments: ["-u", "-c", Self.serverScript],
            requiresFolder: true
        )
        config = entry.makeConfiguration()
        config.environment["CALL_LOG"] = directory.appendingPathComponent("calls").path
        let managedRoot = directory.appendingPathComponent("managed")
        host = MCPHostManager(
            githubOAuth: nil, catalog: try MCPServerCatalog(entries: [entry]),
            connectionDirectory: { managedRoot.appendingPathComponent($0) }
        )
        await host.prepare(servers: [config])
        guard case .connected = host.states[config.id] else {
            XCTFail("Fixture did not connect: \(host.states)")
            return
        }
    }

    override func tearDown() async throws {
        host?.shutdown()
        if let readRoot {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: readRoot.path)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func scope(write: Bool = false) -> ChatToolScope {
        var settings = NativSettings()
        settings.fileReadRootPath = readRoot.path
        settings.fileWriteRootPath = write ? writeRoot.path : nil
        return .standalone(settings: settings)
    }

    private func call(
        _ tool: String, _ arguments: [String: Any] = [:],
        scope: ChatToolScope? = nil, approved: Bool = false,
        current: (() -> ChatToolScope)? = nil
    ) async throws -> String {
        try await host.callTool(
            named: "mcp__filesystem__\(tool)",
            argumentsJSON: String(
                decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self),
            projectScope: scope ?? self.scope(), currentProjectScope: current,
            fileWriteApprovalGranted: approved
        )
    }

    func testReadPermissionDoesNotAdvertiseOrAllowWrites() async throws {
        let names = host.toolDefinitions(projectScope: scope()).map(\.function.name)
        XCTAssertTrue(names.contains("mcp__filesystem__read_text_file"))
        XCTAssertFalse(names.contains("mcp__filesystem__write_file"))
        do {
            _ = try await call("write_file", ["path": "new.txt", "content": "unsafe"])
            XCTFail("File Read must not grant writes")
        } catch {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: readRoot.appendingPathComponent("new.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("calls").path))
    }

    func testWritesUseSeparateWriteFolderAndRequireProtectedFileApproval() async throws {
        let scope = scope(write: true)
        let arguments = #"{"path":"AGENTS.md","content":"instructions"}"#
        XCTAssertTrue(
            host.requiresFileWriteApproval(
                named: "mcp__filesystem__write_file", argumentsJSON: arguments, projectScope: scope
            ))
        do {
            _ = try await call(
                "write_file", ["path": "AGENTS.md", "content": "instructions"], scope: scope)
            XCTFail("Expected protected file approval")
        } catch {}
        _ = try await call(
            "write_file", ["path": "AGENTS.md", "content": "instructions"], scope: scope,
            approved: true)
        XCTAssertEqual(
            try String(contentsOf: writeRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8),
            "instructions")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: readRoot.appendingPathComponent("AGENTS.md").path))
        do {
            _ = try await call(
                "write_file",
                ["path": readRoot.appendingPathComponent("bad.txt").path, "content": "unsafe"],
                scope: scope)
            XCTFail("Read folder must remain outside write authorization")
        } catch {}
    }

    func testWriteOnlyAuthorizationDoesNotRequireAReadFolder() async throws {
        var settings = NativSettings()
        settings.fileWriteRootPath = writeRoot.path
        let scope = ChatToolScope.standalone(settings: settings)
        let names = host.toolDefinitions(projectScope: scope).map(\.function.name)
        XCTAssertFalse(names.contains("mcp__filesystem__read_text_file"))
        XCTAssertTrue(names.contains("mcp__filesystem__write_file"))
        _ = try await call("write_file", ["path": "new.txt", "content": "safe"], scope: scope)
        XCTAssertEqual(
            try String(contentsOf: writeRoot.appendingPathComponent("new.txt"), encoding: .utf8),
            "safe")
    }

    func testReadOnlyFolderCanServeReads() async throws {
        try Data("readable".utf8).write(to: readRoot.appendingPathComponent("read.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: readRoot.path)
        let result = try await call("read_text_file", ["path": "read.txt"])
        XCTAssertEqual(result, "readable")
    }

    func testRecursiveAndDirectListingsExcludeProtectedPathsAndSymlinks() async throws {
        let protected = readRoot.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: protected.appendingPathComponent("private-config"))
        try Data("secret".utf8).write(to: readRoot.appendingPathComponent(".env"))
        try Data("public".utf8).write(to: readRoot.appendingPathComponent("visible.txt"))
        try FileManager.default.createSymbolicLink(
            at: readRoot.appendingPathComponent("alias"), withDestinationURL: protected)
        for tool in [
            "list_directory", "list_directory_with_sizes", "directory_tree", "search_files",
        ] {
            let result = try await call(tool, ["path": ".", "pattern": "**"])
            XCTAssertTrue(result.contains("visible.txt"), tool)
            for hidden in [".ssh", ".env", "private-config", "alias"] {
                XCTAssertFalse(result.contains(hidden), "\(tool): \(result)")
            }
        }
    }

    func testPathRetargetedAfterInitialScopeCheckIsDeniedWithoutServerDispatch() async throws {
        let protected = readRoot.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: protected.appendingPathComponent("private-config"))
        let alias = readRoot.appendingPathComponent("allowed.txt")
        try Data("public".utf8).write(to: alias)
        let scope = scope()
        var checks = 0
        do {
            _ = try await call(
                "read_text_file", ["path": "allowed.txt"], scope: scope,
                current: {
                    checks += 1
                    if checks == 2 {
                        try! FileManager.default.removeItem(at: alias)
                        try! FileManager.default.createSymbolicLink(
                            at: alias,
                            withDestinationURL: protected.appendingPathComponent("private-config"))
                    }
                    return scope
                })
            XCTFail("Retargeted path must be denied")
        } catch {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("calls").path))
    }

    func testNoFollowDirectoryReaderRejectsRetargetedDirectory() throws {
        let candidate = readRoot.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let checked = try FileReadAccessPolicy(rootPath: readRoot.path).resolve(path: "subfolder")
            .url
        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: writeRoot)
        XCTAssertThrowsError(try SafeLocalDirectoryReader().contents(of: checked))
    }

    func testEditedCatalogArgumentsArePreservedWithoutAdditionalRoots() async throws {
        config.arguments.append(readRoot.path)
        await host.prepare(servers: [config])
        let roots = try await call("list_allowed_directories")
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(roots.utf8)) as? [String])
        XCTAssertEqual(parsed, [readRoot.path])
    }

    func testWriteFolderRevocationPreventsDispatch() async throws {
        let scope = scope(write: true)
        do {
            _ = try await call(
                "write_file", ["path": "new.txt", "content": "unsafe"], scope: scope,
                current: { self.scope() })
            XCTFail("Revoked write authorization must be denied")
        } catch {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: writeRoot.appendingPathComponent("new.txt").path)
        )
    }

    func testFutureFilesystemToolsAreHiddenAndDenied() async throws {
        XCTAssertFalse(
            host.toolDefinitions(projectScope: scope()).contains {
                $0.function.name.hasSuffix("__future_tool")
            })
        do {
            _ = try await call("future_tool", ["path": "."])
            XCTFail("Unknown filesystem capabilities must fail closed")
        } catch {}
    }

    func testNativeFileOperationsPreserveTheFilesystemToolContract() async throws {
        let scope = scope(write: true)
        _ = try await call("create_directory", ["path": "nested"], scope: scope)
        _ = try await call(
            "write_file", ["path": "nested/source.txt", "content": "one\ntwo\nthree"], scope: scope)
        _ = try await call(
            "edit_file",
            ["path": "nested/source.txt", "edits": [["oldText": "two", "newText": "changed"]]],
            scope: scope)
        _ = try await call(
            "move_file", ["source": "nested/source.txt", "destination": "nested/destination.txt"],
            scope: scope)
        let destination = writeRoot.appendingPathComponent("nested/destination.txt")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "one\nchanged\nthree")
        var settings = NativSettings()
        settings.fileReadRootPath = writeRoot.path
        let readScope = ChatToolScope.standalone(settings: settings)
        let head = try await call(
            "read_text_file", ["path": "nested/destination.txt", "head": 1], scope: readScope)
        XCTAssertEqual(head, "one")
        let batch = try await call(
            "read_multiple_files", ["paths": ["nested/destination.txt"]], scope: readScope)
        XCTAssertTrue(batch.contains("changed"))
        let info = try await call(
            "get_file_info", ["path": "nested/destination.txt"], scope: readScope)
        XCTAssertTrue(info.contains("isDirectory: false"))
        let search = try await call(
            "search_files", ["path": ".", "pattern": "**/*.txt"], scope: readScope)
        XCTAssertTrue(search.contains("nested/destination.txt"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("calls").path))
    }

    func testSecretRedactionPrecedesHeadAndTailSelection() async throws {
        let content =
            "-----BEGIN PRIVATE KEY-----\nsynthetic-key-material\n-----END PRIVATE KEY-----"
        try Data(content.utf8).write(to: readRoot.appendingPathComponent("notes.txt"))
        let result = try await call("read_text_file", ["path": "notes.txt", "head": 2])
        XCTAssertFalse(result.contains("synthetic-key-material"))
        XCTAssertTrue(result.contains("<redacted>"))
    }

    func testProjectProtectedWritesUseTheSameApprovalGate() async throws {
        let scope = ChatToolScope(
            projectID: UUID(), projectName: "Project", rootPath: writeRoot.path,
            projectToolsEnabled: true
        )
        do {
            _ = try await call(
                "write_file", ["path": "CLAUDE.md", "content": "unsafe"], scope: scope)
            XCTFail("Project instructions must require approval")
        } catch {}
        _ = try await call(
            "write_file", ["path": "CLAUDE.md", "content": "approved"], scope: scope, approved: true
        )
        XCTAssertEqual(
            try String(contentsOf: writeRoot.appendingPathComponent("CLAUDE.md"), encoding: .utf8),
            "approved")
    }

    func testWorktreeScopeUsesCheckoutInsteadOfStandaloneWriteFolder() async throws {
        let checkout = ChatGitWorktree(
            repositoryPath: readRoot.path,
            commonDirectory: readRoot.appendingPathComponent(".git").path,
            path: writeRoot.path, projectSubpath: "", branch: "codex/test", baseCommit: "test"
        )
        let scope = ChatToolScope(
            projectID: nil, projectName: "Checkout", rootPath: writeRoot.path,
            projectToolsEnabled: true, standaloneWriteRootPath: readRoot.path, worktree: checkout
        )
        XCTAssertTrue(scope.isProject)
        XCTAssertEqual(scope.fileWriteRootPath, writeRoot.path)
        _ = try await call(
            "write_file", ["path": "checkout.txt", "content": "worktree"], scope: scope
        )
        let content = try await call("read_text_file", ["path": "checkout.txt"], scope: scope)
        XCTAssertEqual(content, "worktree")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: readRoot.appendingPathComponent("checkout.txt").path)
        )
    }

    private static let serverScript = #"""
        import json, os, pathlib, sys
        tools = ['read_file', 'read_text_file', 'read_media_file', 'read_multiple_files', 'write_file', 'edit_file', 'create_directory', 'list_directory', 'list_directory_with_sizes', 'directory_tree', 'move_file', 'search_files', 'get_file_info', 'list_allowed_directories', 'future_tool']
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request['method']
            if method == 'initialize':
                result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
            elif method == 'tools/list':
                result = {'tools': [{'name': name, 'description': name, 'inputSchema': {'type': 'object'}} for name in tools]}
            elif method == 'tools/call':
                pathlib.Path(os.environ['CALL_LOG']).write_text('dispatched')
                result = {'content': [{'type': 'text', 'text': json.dumps(sys.argv[1:])}]}
            else: result = {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """#
}
