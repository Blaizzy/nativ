import Foundation
import NativServerKit
import XCTest

final class ChatSearchFilesToolTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChatSearchFilesToolTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testSchemaIsBoundedAndPinsSupportedParameters() throws {
        let data = try JSONEncoder().encode(ChatSearchFilesToolRegistry.definition)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "search_files")
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(parameters["required"] as? [String], ["pattern"])
        XCTAssertEqual(
            Set(properties.keys),
            Set([
                "pattern", "target", "path", "file_glob", "limit", "offset",
                "output_mode", "context",
            ])
        )
    }

    func testEngineBuildsDeterministicSafeArgumentsAndParsesJSON() async throws {
        let output = """
            {"type":"begin","data":{"path":{"text":"/tmp/a.swift"}}}
            {"type":"match","data":{"path":{"text":"/tmp/a.swift"},"lines":{"text":"let value = 1\\n"},"line_number":7,"absolute_offset":10,"submatches":[]}}
            {"type":"end","data":{"path":{"text":"/tmp/a.swift"},"binary_offset":null,"stats":{}}}
            """ + "\n"
        let engine = RipgrepSearchEngine(
            locateExecutable: { URL(fileURLWithPath: "/tools/rg") },
            runProcess: { _, arguments in
                XCTAssertTrue(arguments.starts(with: ["--no-config", "--color", "never"]))
                XCTAssertTrue(arguments.contains("--sort"))
                XCTAssertTrue(arguments.contains("!**/.ssh/**"))
                XCTAssertEqual(Array(arguments.suffix(3)), ["--", "value", "/tmp"])
                return FileSearchProcessResult(
                    stdout: Data(output.utf8),
                    stderr: Data(),
                    terminationStatus: 0,
                    wasTerminatedForOutputLimit: false
                )
            }
        )
        let result = try await engine.search(
            FileSearchRequest(
                target: .content,
                pattern: "value",
                rootURL: URL(fileURLWithPath: "/tmp"),
                fileGlob: "*.swift",
                context: 2
            ))

        XCTAssertEqual(
            result.contentLines,
            [
                FileSearchContentLine(
                    path: "/tmp/a.swift",
                    lineNumber: 7,
                    text: "let value = 1",
                    isMatch: true
                )
            ])
    }

    func testLiveBundledRipgrepSearchesContentsAndFiles() async throws {
        try write("Sources/App.swift", "let alpha = 1\nlet beta = alpha\n")
        try write("Sources/Notes.txt", "alpha\n")
        try write("credentials.json", "alpha\n")
        try write("public.json", "alpha\n")
        let executable =
            repositoryRoot
            .appendingPathComponent("ThirdParty/ripgrep/Tools/rg")
        let engine = RipgrepSearchEngine(locateExecutable: { executable })

        let content = try await engine.search(
            FileSearchRequest(
                target: .content,
                pattern: "alpha",
                rootURL: rootURL,
                fileGlob: "*.swift",
                context: 1
            ))
        XCTAssertEqual(content.contentLines.filter(\.isMatch).count, 2)
        XCTAssertTrue(content.contentLines.allSatisfy { $0.path.hasSuffix("App.swift") })

        let excluded = try await engine.search(
            FileSearchRequest(
                target: .content,
                pattern: "alpha",
                rootURL: rootURL,
                fileGlob: "*.json",
                context: 0
            ))
        XCTAssertEqual(excluded.contentLines.filter(\.isMatch).count, 1)
        XCTAssertTrue(excluded.contentLines[0].path.hasSuffix("public.json"))

        let files = try await engine.search(
            FileSearchRequest(
                target: .files,
                pattern: "*.swift",
                rootURL: rootURL,
                fileGlob: nil,
                context: 0
            ))
        XCTAssertEqual(files.filePaths.count, 1)
        XCTAssertTrue(files.filePaths[0].hasSuffix("App.swift"))
    }

    func testLiveEngineReportsInvalidRegex() async {
        let executable =
            repositoryRoot
            .appendingPathComponent("ThirdParty/ripgrep/Tools/rg")
        let engine = RipgrepSearchEngine(locateExecutable: { executable })

        do {
            _ = try await engine.search(
                FileSearchRequest(
                    target: .content,
                    pattern: "(",
                    rootURL: rootURL,
                    fileGlob: nil,
                    context: 0
                ))
            XCTFail("Expected invalid regex to fail")
        } catch let error as FileSearchEngineError {
            XCTAssertEqual(error, .invalidPattern)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testContentModePaginatesContextAndRedactsOnlySecretValues() async throws {
        try write("app.txt", "before\napi_key=sk-proj-abcdefghijklmnopqrstuv\nafter\n")
        let raw = FileSearchRawResult(contentLines: [
            line("app.txt", 1, "before", match: false),
            line("app.txt", 2, "api_key=sk-proj-abcdefghijklmnopqrstuv", match: true),
            line("app.txt", 3, "after", match: false),
        ])
        let payload = try await execute(
            ["pattern": "api_key", "context": 1, "limit": 1],
            result: raw
        )
        let matches = try XCTUnwrap(payload["matches"] as? [[String: Any]])
        let first = try XCTUnwrap(matches.first)
        let before = try XCTUnwrap(first["context_before"] as? [[String: Any]])
        let after = try XCTUnwrap(first["context_after"] as? [[String: Any]])

        XCTAssertEqual(first["path"] as? String, "app.txt")
        XCTAssertEqual(first["line"] as? Int, 2)
        XCTAssertEqual(first["text"] as? String, "api_key=<redacted>")
        XCTAssertEqual(before.first?["text"] as? String, "before")
        XCTAssertEqual(after.first?["text"] as? String, "after")
        XCTAssertEqual(payload["redacted"] as? Bool, true)
    }

    func testContentOutputModesReturnUniqueFilesAndCounts() async throws {
        try write("a.txt", "one\ntwo\n")
        try write("b.txt", "one\n")
        let raw = FileSearchRawResult(contentLines: [
            line("a.txt", 1, "one", match: true),
            line("a.txt", 2, "two", match: true),
            line("b.txt", 1, "one", match: true),
        ])

        let filesOnly = try await execute(
            ["pattern": "one", "output_mode": "files_only"],
            result: raw
        )
        XCTAssertEqual(filesOnly["matches"] as? [String], ["a.txt", "b.txt"])

        let count = try await execute(
            ["pattern": "one", "output_mode": "count"],
            result: raw
        )
        let counts = try XCTUnwrap(count["matches"] as? [[String: Any]])
        XCTAssertEqual(counts.map { $0["path"] as? String }, ["a.txt", "b.txt"])
        XCTAssertEqual(counts.map { $0["count"] as? Int }, [2, 1])
    }

    func testFilesModeSortsNewestFirstAndPaginates() async throws {
        try write("old.txt", "old")
        try write("new.txt", "new")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: rootURL.appendingPathComponent("old.txt").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: rootURL.appendingPathComponent("new.txt").path
        )
        let payload = try await execute(
            ["pattern": "*.txt", "target": "files", "limit": 1],
            result: FileSearchRawResult(filePaths: [
                rootURL.appendingPathComponent("old.txt").path,
                rootURL.appendingPathComponent("new.txt").path,
            ])
        )
        let matches = try XCTUnwrap(payload["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.first?["path"] as? String, "new.txt")
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(payload["next_offset"] as? Int, 1)
    }

    func testSearchRejectsEscapesCredentialsAndInvalidModeCombinations() async {
        let outside = await failure(["pattern": "x", "path": "../outside"])
        let credential = await failure(["pattern": "x", "path": ".env"])
        let invalid = await failure([
            "pattern": "*.swift", "target": "files", "output_mode": "count",
        ])

        XCTAssertEqual(errorCode(outside), "outside_allowed_root")
        XCTAssertEqual(errorCode(credential), "blocked_credential_path")
        XCTAssertEqual(errorCode(invalid), "invalid_arguments")
    }

    func testReturnedCredentialPathsAreFilteredEvenIfEngineReportsThem() async throws {
        try write("credentials.json", "token")
        let raw = FileSearchRawResult(contentLines: [
            line("credentials.json", 1, "token", match: true)
        ])
        let payload = try await execute(["pattern": "token"], result: raw)
        XCTAssertEqual((payload["matches"] as? [Any])?.count, 0)
    }

    func testRepeatedIdenticalSearchWarnsThenBlocks() async throws {
        try write("a.txt", "value\n")
        let tracker = ChatSearchFilesTracker()
        var context = makeContext(
            result: FileSearchRawResult(contentLines: [
                line("a.txt", 1, "value", match: true)
            ]))
        context.fileSearchTracker = tracker
        let call = try makeCall(["pattern": "value"])

        _ = try await ChatSearchFilesToolExecutor().execute(call: call, context: context)
        let second = try await ChatSearchFilesToolExecutor().execute(call: call, context: context)
        XCTAssertTrue(second.contains("identical search"))
        do {
            _ = try await ChatSearchFilesToolExecutor().execute(call: call, context: context)
            XCTFail("Expected the third identical search to be blocked")
        } catch let error as ChatSearchFilesToolError {
            XCTAssertEqual(error, .repeatedSearchBlocked)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingPathIsNegativelyCached() async {
        let recorder = SearchCallRecorder()
        var context = makeContext(result: FileSearchRawResult())
        context.fileSearchTracker = ChatSearchFilesTracker()
        context.fileSearchToolDependencies = ChatSearchFilesToolDependencies(search: { _ in
            await recorder.record()
            return FileSearchRawResult()
        })
        let call = try! makeCall(["pattern": "x", "path": "missing"])
        for _ in 0 ..< 2 {
            do {
                _ = try await ChatSearchFilesToolExecutor().execute(call: call, context: context)
            } catch {
                XCTAssertEqual(error as? ChatSearchFilesToolError, .pathNotFound(hint: nil))
            }
        }
        let callCount = await recorder.count
        XCTAssertEqual(callCount, 0)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func line(
        _ relativePath: String,
        _ line: Int,
        _ text: String,
        match: Bool
    ) -> FileSearchContentLine {
        FileSearchContentLine(
            path: rootURL.appendingPathComponent(relativePath).path,
            lineNumber: line,
            text: text,
            isMatch: match
        )
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func execute(
        _ arguments: [String: Any],
        result: FileSearchRawResult
    ) async throws -> [String: Any] {
        let content = try await ChatSearchFilesToolExecutor().execute(
            call: try makeCall(arguments),
            context: makeContext(result: result)
        )
        return try json(content)
    }

    private func failure(_ arguments: [String: Any]) async -> [String: Any] {
        do {
            _ = try await ChatSearchFilesToolExecutor().execute(
                call: try makeCall(arguments),
                context: makeContext(result: FileSearchRawResult())
            )
            XCTFail("Expected search_files to fail")
            return [:]
        } catch {
            return (try? json(ChatSearchFilesToolExecutor().failurePayload(error: error))) ?? [:]
        }
    }

    private func makeContext(result: FileSearchRawResult) -> ChatToolExecutionContext {
        var context = ChatToolExecutionContext(
            imageGenerationModelID: nil,
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: nil,
            imageReferences: [],
            modelSearchPath: "",
            additionalModelSearchPaths: [],
            fileReadRootPath: rootURL.path
        )
        context.fileSearchToolDependencies = ChatSearchFilesToolDependencies(search: { _ in result }
        )
        return context
    }

    private func makeCall(_ arguments: [String: Any]) throws -> MLXChatToolCall {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return MLXChatToolCall(
            id: "search",
            function: MLXChatFunctionCall(
                name: ChatSearchFilesToolRegistry.toolName,
                arguments: String(decoding: data, as: UTF8.self)
            )
        )
    }

    private func json(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        )
    }

    private func errorCode(_ payload: [String: Any]) -> String? {
        (payload["error"] as? [String: Any])?["code"] as? String
    }
}

private actor SearchCallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
