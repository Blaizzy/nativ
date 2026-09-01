import Foundation
import NativServerKit
import XCTest

final class ChatFileWriteToolTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChatFileWriteToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testSchemasAreBoundedAndRequireWriteContent() throws {
        let write = try schema(ChatFileWriteToolRegistry.writeDefinition)
        XCTAssertEqual(write.function["name"] as? String, "write_file")
        XCTAssertTrue(
            (write.function["description"] as? String)?.contains(
                "diff may be a truncated preview"
            ) == true
        )
        XCTAssertEqual(write.parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(write.parameters["required"] as? [String], ["path", "content"])

        let patch = try schema(ChatFileWriteToolRegistry.patchDefinition)
        XCTAssertEqual(patch.function["name"] as? String, "patch")
        XCTAssertEqual(patch.parameters["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(patch.parameters["properties"] as? [String: Any])
        XCTAssertNotNil(properties["replace_all"])
        XCTAssertEqual(
            Set(properties.keys),
            Set(["mode", "path", "old_string", "new_string", "patch", "replace_all"])
        )

        let writeProperties = try XCTUnwrap(write.parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(writeProperties.keys), Set(["path", "content"]))
    }

    func testWriteCreatesParentsOverwritesAndVerifiesHash() async throws {
        let first = try await executeWrite(path: "nested/notes.txt", content: "one\n")
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual(first["verified"] as? Bool, true)
        XCTAssertEqual((first["sha256"] as? String)?.count, 64)
        XCTAssertEqual(first["bytes_written"] as? Int, 4)
        XCTAssertEqual(first["lines_written"] as? Int, 1)
        XCTAssertEqual(first["diff_truncated"] as? Bool, false)
        XCTAssertEqual(first["files_modified"] as? [String], ["nested/notes.txt"])
        XCTAssertEqual(try read("nested/notes.txt"), "one\n")

        _ = try await executeWrite(path: "nested/notes.txt", content: "")
        XCTAssertEqual(try read("nested/notes.txt"), "")
    }

    func testWriteDiffPreviewUses100KCapAndReportsTruncation() async throws {
        let contentBelowCap = String(repeating: "x", count: 75_000)
        let belowCap = try await executeWrite(path: "below.txt", content: contentBelowCap)
        XCTAssertEqual(belowCap["diff_truncated"] as? Bool, false)
        XCTAssertTrue((belowCap["diff"] as? String)?.count ?? 0 > 50_000)

        let contentAboveCap = String(repeating: "y", count: 110_000)
        let aboveCap = try await executeWrite(path: "above.txt", content: contentAboveCap)
        XCTAssertEqual(aboveCap["diff_truncated"] as? Bool, true)
        XCTAssertEqual(aboveCap["bytes_written"] as? Int, contentAboveCap.utf8.count)
        XCTAssertEqual(aboveCap["lines_written"] as? Int, 1)
        XCTAssertTrue(
            (aboveCap["_hint"] as? String)?.contains(
                "Only the diff preview was truncated"
            ) == true
        )
        let diff = try XCTUnwrap(aboveCap["diff"] as? String)
        XCTAssertEqual(
            diff.count,
            FileUnifiedDiff.maximumCharacters + "\n... diff truncated".count
        )
    }

    func testWriteRejectsEscapesBinaryDocumentsAndReadDumps() async {
        let escape = await failureCode(writePath: "../outside.txt", content: "no")
        let binary = await failureCode(writePath: "report.pdf", content: "plain text")
        let dump = await failureCode(writePath: "notes.txt", content: "1|one\n2|two")
        XCTAssertEqual(escape, "outside_allowed_root")
        XCTAssertEqual(binary, "binary_document")
        XCTAssertEqual(dump, "read_dump_rejected")
    }

    func testProtectedInstructionWriteRequiresApproval() async throws {
        let call = try makeCall(
            name: ChatFileWriteToolRegistry.writeToolName,
            object: ["path": "AGENTS.md", "content": "instructions\n"]
        )
        XCTAssertTrue(
            ChatFileWriteApprovalPolicy.requiresApproval(
                call: call,
                rootPath: rootURL.path
            ))

        do {
            _ = try await execute(call)
            XCTFail("Expected approval to be required")
        } catch {
            XCTAssertEqual(error as? ChatFileWriteToolError, .approvalRequired)
        }

        var context = makeContext()
        context.fileWriteApprovalGranted = true
        _ = try await ChatFileWriteToolExecutor().execute(call: call, context: context)
        XCTAssertEqual(try read("AGENTS.md"), "instructions\n")
    }

    func testPatchReplacesWithWhitespaceToleranceAndReplaceAll() async throws {
        try write("let value = 1\nlet value = 1\n", to: "code.swift")
        let result = try await executePatch([
            "path": "code.swift",
            "old_string": "let   value=1",
            "new_string": "let value = 2",
            "replace_all": true,
        ])

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(try read("code.swift"), "let value = 2\nlet value = 2\n")
        XCTAssertTrue((result["diff"] as? String)?.contains("+let value = 2") == true)
    }

    func testPatchRequiresUniqueMatchUnlessReplaceAllIsSet() async throws {
        try write("same\nsame\n", to: "notes.txt")
        let payload = await failure(patch: [
            "path": "notes.txt", "old_string": "same", "new_string": "changed",
        ])
        XCTAssertEqual(errorCode(in: payload), "ambiguous_match")
        XCTAssertEqual(try read("notes.txt"), "same\nsame\n")
    }

    func testRepeatedMissingReplacementEscalatesHint() async throws {
        try write("actual\n", to: "notes.txt")
        let arguments: [String: Any] = [
            "path": "notes.txt", "old_string": "missing", "new_string": "new",
        ]
        let first = await failure(patch: arguments)
        let second = await failure(patch: arguments)
        XCTAssertTrue(errorHint(in: first)?.contains("surrounding context") == true)
        XCTAssertTrue(errorHint(in: second)?.contains("Re-read") == true)
    }

    func testV4APatchAddsUpdatesDeletesAndMovesFiles() async throws {
        try write("old\n", to: "update.txt")
        try write("delete me\n", to: "delete.txt")
        try write("move me\n", to: "move.txt")
        let patch = """
            *** Begin Patch
            *** Add File: added.txt
            +added
            *** Update File: update.txt
            @@
            -old
            +new
            *** Delete File: delete.txt
            *** Move File: move.txt
            *** Move to: moved.txt
            *** End Patch
            """

        let result = try await executePatch(["mode": "patch", "patch": patch])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(try read("added.txt"), "added\n")
        XCTAssertEqual(try read("update.txt"), "new\n")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("delete.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("move.txt").path))
        XCTAssertEqual(try read("moved.txt"), "move me\n")
    }

    func testV4AAddDoesNotOverwriteExistingFile() async throws {
        try write("keep\n", to: "existing.txt")
        let patch = """
            *** Begin Patch
            *** Add File: existing.txt
            +replace
            *** End Patch
            """
        let payload = await failure(patch: ["mode": "patch", "patch": patch])
        XCTAssertEqual(errorCode(in: payload), "file_already_exists")
        XCTAssertEqual(try read("existing.txt"), "keep\n")
    }

    func testJSONLintReturnsOnlyNewErrors() async throws {
        let valid = try await executeWrite(path: "settings.json", content: #"{"ok":true}"#)
        XCTAssertEqual(valid["lint_errors"] as? [String], [])

        let invalid = try await executeWrite(path: "settings.json", content: #"{"ok":}"#)
        let errors = try XCTUnwrap(invalid["lint_errors"] as? [String])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].hasPrefix("JSON:"))
    }

    func testWarnsWhenFileChangedAfterThisRunReadIt() async throws {
        try write("one\n", to: "notes.txt")
        let runID = UUID()
        var readContext = makeContext()
        readContext.fileReadRootPath = rootURL.path
        readContext.fileOperationRunID = runID
        let readCall = try makeCall(
            name: ChatReadFileToolRegistry.toolName,
            object: ["path": "notes.txt"]
        )
        _ = try await ChatReadFileToolExecutor().execute(
            call: readCall,
            context: readContext
        )
        try write("external\n", to: "notes.txt")

        var context = makeContext()
        context.fileOperationRunID = runID
        let result = try await executeWrite(
            path: "notes.txt",
            content: "agent\n",
            context: context
        )
        XCTAssertTrue((result["_warning"] as? String)?.contains("last read") == true)
    }

    private func executeWrite(
        path: String,
        content: String,
        context: ChatToolExecutionContext? = nil
    ) async throws -> [String: Any] {
        let call = try makeCall(
            name: ChatFileWriteToolRegistry.writeToolName,
            object: ["path": path, "content": content]
        )
        return try decode(try await execute(call, context: context))
    }

    private func executePatch(_ arguments: [String: Any]) async throws -> [String: Any] {
        try decode(
            try await execute(
                makeCall(
                    name: ChatFileWriteToolRegistry.patchToolName,
                    object: arguments
                )))
    }

    private func execute(
        _ call: MLXChatToolCall,
        context: ChatToolExecutionContext? = nil
    ) async throws -> String {
        try await ChatFileWriteToolExecutor().execute(
            call: call,
            context: context ?? makeContext()
        )
    }

    private func failureCode(writePath: String, content: String) async -> String? {
        do {
            _ = try await executeWrite(path: writePath, content: content)
            XCTFail("Expected write_file to fail")
            return nil
        } catch {
            return errorCode(in: failurePayload(error))
        }
    }

    private func failure(patch arguments: [String: Any]) async -> [String: Any] {
        do {
            _ = try await executePatch(arguments)
            XCTFail("Expected patch to fail")
            return [:]
        } catch {
            return failurePayload(error)
        }
    }

    private func failurePayload(_ error: Error) -> [String: Any] {
        (try? decode(ChatFileWriteToolExecutor().failurePayload(error: error))) ?? [:]
    }

    private func makeContext() -> ChatToolExecutionContext {
        var context = ChatToolExecutionContext(
            imageGenerationModelID: nil,
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: nil,
            imageReferences: [],
            modelSearchPath: "",
            additionalModelSearchPaths: []
        )
        context.fileWriteRootPath = rootURL.path
        return context
    }

    private func makeCall(name: String, object: [String: Any]) throws -> MLXChatToolCall {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return MLXChatToolCall(
            id: UUID().uuidString,
            function: MLXChatFunctionCall(
                name: name,
                arguments: String(decoding: data, as: UTF8.self)
            )
        )
    }

    private func schema(
        _ definition: MLXChatToolDefinition
    ) throws -> (function: [String: Any], parameters: [String: Any]) {
        let data = try JSONEncoder().encode(definition)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let function = try XCTUnwrap(root["function"] as? [String: Any])
        return (function, try XCTUnwrap(function["parameters"] as? [String: Any]))
    }

    private func write(_ text: String, to relativePath: String) throws {
        try text.write(
            to: rootURL.appendingPathComponent(relativePath),
            atomically: true,
            encoding: .utf8
        )
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: rootURL.appendingPathComponent(relativePath),
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

    private func errorHint(in payload: [String: Any]) -> String? {
        (payload["error"] as? [String: Any])?["hint"] as? String
    }
}
