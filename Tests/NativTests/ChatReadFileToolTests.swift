import Darwin
import Foundation
import NativServerKit
import XCTest

final class ChatReadFileToolTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatReadFileToolTests-\(UUID().uuidString)", isDirectory: true)
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

    func testSchemaIsBoundedAndRequiresPath() throws {
        let data = try JSONEncoder().encode(ChatReadFileToolRegistry.definition)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let function = try XCTUnwrap(root["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let limit = try XCTUnwrap(properties["limit"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "read_file")
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(parameters["required"] as? [String], ["path"])
        XCTAssertEqual(limit["maximum"] as? Int, 2_000)
        XCTAssertEqual(limit["default"] as? Int, 2_000)
    }

    func testReadsNumberedPaginatedLines() async throws {
        try write("alpha\nbeta\ngamma\n", to: "notes.txt")
        let result = try await execute(path: "notes.txt", offset: 2, limit: 1)

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["path"] as? String, "notes.txt")
        XCTAssertEqual(result["content"] as? String, "2|beta")
        XCTAssertEqual(result["total_lines"] as? Int, 3)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual(result["truncated_by"] as? String, "lines")
        XCTAssertEqual(result["next_offset"] as? Int, 3)
    }

    func testClampsPaginationAndHandlesPastEOF() async throws {
        try write("one\ntwo", to: "notes.txt")
        let result = try await execute(path: "notes.txt", offset: -4, limit: 9_000)
        XCTAssertEqual(result["offset"] as? Int, 1)
        XCTAssertEqual(result["limit"] as? Int, 2_000)
        XCTAssertEqual(result["content"] as? String, "1|one\n2|two")

        let pastEOF = try await execute(path: "notes.txt", offset: 50, limit: 2)
        XCTAssertEqual(pastEOF["content"] as? String, "")
        XCTAssertEqual(pastEOF["truncated"] as? Bool, false)
        XCTAssertTrue((pastEOF["warnings"] as? [String])?.first?.contains("past") == true)
    }

    func testTruncatesHugeLineToMaximumAndAdvances() async throws {
        try write(String(repeating: "x", count: 100) + "\nnext", to: "minified.txt")
        let result = try await execute(
            path: "minified.txt",
            maximumCharacters: 20
        )

        let content = try XCTUnwrap(result["content"] as? String)
        XCTAssertEqual(content.count, 20)
        XCTAssertTrue(content.hasPrefix("1|"))
        XCTAssertEqual(result["truncated_by"] as? String, "characters")
        XCTAssertEqual(result["next_offset"] as? Int, 2)
        XCTAssertTrue((result["warnings"] as? [String])?.contains(where: {
            $0.contains("Line 1")
        }) == true)
    }

    func testRedactsOnlySecretValuesAndPreservesOtherText() async throws {
        let secret = "sk-proj-abcdefghijklmnopqrstuv"
        let password = "correct-horse@battery$staple"
        try write(
            "name=demo\napi_key=\(secret)\npassword=\"\(password)\"\nmode=test",
            to: "config.txt"
        )
        let result = try await execute(path: "config.txt")
        let content = try XCTUnwrap(result["content"] as? String)

        XCTAssertFalse(content.contains(secret))
        XCTAssertFalse(content.contains(password))
        XCTAssertTrue(content.contains("2|api_key=<redacted>"))
        XCTAssertTrue(content.contains("3|password=\"<redacted>\""))
        XCTAssertTrue(content.contains("1|name=demo"))
        XCTAssertTrue(content.contains("4|mode=test"))
        XCTAssertEqual(result["redacted"] as? Bool, true)
    }

    func testAllowsInternalSymlinkButBlocksSymlinkEscape() async throws {
        try write("inside", to: "target.txt")
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("inside-link.txt"),
            withDestinationURL: rootURL.appendingPathComponent("target.txt")
        )
        let internalResult = try await execute(path: "inside-link.txt")
        XCTAssertEqual(internalResult["content"] as? String, "1|inside")

        let outside = rootURL.deletingLastPathComponent().appendingPathComponent("private.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: rootURL.appendingPathComponent("outside-link.txt"),
            withDestinationURL: outside
        )
        let escapeFailure = await failure(path: "outside-link.txt")
        XCTAssertEqual(errorCode(in: escapeFailure), "outside_allowed_root")
    }

    func testBlocksCredentialPathsAndRootEscape() async throws {
        try write("SECRET=value", to: ".env")
        let credentialFailure = await failure(path: ".env")
        XCTAssertEqual(errorCode(in: credentialFailure), "blocked_credential_path")

        let outside = rootURL.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapeFailure = await failure(path: "../outside.txt")
        XCTAssertEqual(errorCode(in: escapeFailure), "outside_allowed_root")
    }

    func testBlocksBinaryFilesAndFIFOs() async throws {
        let binaryURL = rootURL.appendingPathComponent("image.dat")
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 1]).write(to: binaryURL)
        let binaryFailure = await failure(path: "image.dat")
        XCTAssertEqual(errorCode(in: binaryFailure), "binary_file")

        try Data("plain\0text".utf8).write(to: rootURL.appendingPathComponent("nul-data"))
        let nulFailure = await failure(path: "nul-data")
        XCTAssertEqual(errorCode(in: nulFailure), "binary_file")

        let fifoURL = rootURL.appendingPathComponent("pipe")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, 0o600), 0)
        let pipeFailure = await failure(path: "pipe")
        XCTAssertEqual(errorCode(in: pipeFailure), "unsupported_file_type")
    }

    func testSuggestsSimilarFileForMissingPath() async throws {
        try write("hello", to: "ReadMe.md")
        let payload = await failure(path: "ReadMee.md")
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "file_not_found")
        XCTAssertTrue((error["hint"] as? String)?.contains("ReadMe.md") == true)
    }

    func testDeduplicatesThenBlocksRepeatedUnchangedWindow() async throws {
        try write("one\ntwo", to: "notes.txt")
        let tracker = ChatReadFileTracker()
        _ = try await execute(path: "notes.txt", tracker: tracker)
        let duplicate = try await execute(path: "notes.txt", tracker: tracker)
        XCTAssertEqual(duplicate["dedup"] as? Bool, true)
        XCTAssertEqual(duplicate["content_returned"] as? Bool, false)

        let blocked = await failure(path: "notes.txt", tracker: tracker)
        XCTAssertEqual(errorCode(in: blocked), "repeated_read_blocked")
    }

    func testUsesExistingPDFExtractionDependency() async throws {
        let pdfURL = rootURL.appendingPathComponent("document.pdf")
        try Data("%PDF-stub".utf8).write(to: pdfURL)
        let dependencies = ChatReadFileToolDependencies(
            read: { url in try await SafeLocalFileReader().read(url: url) },
            extractPDF: { _, filename in
                ExtractedDocumentContent(
                    filename: filename,
                    mimeType: "application/pdf",
                    pageCount: 2,
                    sections: [ExtractedDocumentSection(pageNumber: 1, text: "PDF text")]
                )
            }
        )
        let result = try await execute(path: "document.pdf", dependencies: dependencies)

        XCTAssertEqual(result["extracted_document"] as? Bool, true)
        XCTAssertEqual(result["content"] as? String, "1|[Page 1]\n2|PDF text")
        XCTAssertTrue((result["warnings"] as? [String])?.contains(where: {
            $0.contains("no extractable text")
        }) == true)
    }

    private func execute(
        path: String,
        offset: Int? = nil,
        limit: Int? = nil,
        tracker: ChatReadFileTracker = ChatReadFileTracker(),
        maximumCharacters: Int = ChatReadFileToolRegistry.defaultMaximumResultCharacters,
        dependencies: ChatReadFileToolDependencies = .live
    ) async throws -> [String: Any] {
        var arguments: [String: Any] = ["path": path]
        if let offset { arguments["offset"] = offset }
        if let limit { arguments["limit"] = limit }
        let argumentsData = try JSONSerialization.data(withJSONObject: arguments)
        let call = MLXChatToolCall(
            id: UUID().uuidString,
            function: MLXChatFunctionCall(
                name: ChatReadFileToolRegistry.toolName,
                arguments: String(decoding: argumentsData, as: UTF8.self)
            )
        )
        var context = ChatToolExecutionContext(
            imageGenerationModelID: nil,
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: nil,
            imageReferences: [],
            modelSearchPath: "",
            additionalModelSearchPaths: []
        )
        context.fileReadRootPath = rootURL.path
        context.fileReadTracker = tracker
        context.fileReadMaximumResultCharacters = maximumCharacters
        context.fileReadToolDependencies = dependencies
        let content = try await ChatReadFileToolExecutor().execute(call: call, context: context)
        return try decode(content)
    }

    private func failure(
        path: String,
        tracker: ChatReadFileTracker = ChatReadFileTracker()
    ) async -> [String: Any] {
        do {
            _ = try await execute(path: path, tracker: tracker)
            XCTFail("Expected read_file to fail")
            return [:]
        } catch {
            return (try? decode(ChatReadFileToolExecutor().failurePayload(error: error))) ?? [:]
        }
    }

    private func write(_ text: String, to relativePath: String) throws {
        try text.write(
            to: rootURL.appendingPathComponent(relativePath),
            atomically: true,
            encoding: .utf8
        )
    }

    private func decode(_ string: String) throws -> [String: Any] {
        let data = try XCTUnwrap(string.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func errorCode(in payload: [String: Any]) -> String? {
        (payload["error"] as? [String: Any])?["code"] as? String
    }
}
