import Foundation
import NativServerKit
import XCTest

final class NativMCPClientTests: XCTestCase {
    // MARK: - MCPLineFramer

    func testLineFramerBuffersTruncatedChunkUntilNewlineArrives() {
        var buffer = ""
        let firstChunk = MCPLineFramer.extractLines(appending: #"{"jsonrpc":"2.0","#, to: &buffer)
        XCTAssertEqual(firstChunk, [])
        XCTAssertFalse(buffer.isEmpty)

        let secondChunk = MCPLineFramer.extractLines(appending: "\"id\":1,\"result\":{}}\n", to: &buffer)
        XCTAssertEqual(secondChunk, [#"{"jsonrpc":"2.0","id":1,"result":{}}"#])
        XCTAssertEqual(buffer, "")
    }

    func testLineFramerHandlesMultipleLinesInOneChunk() {
        var buffer = ""
        let lines = MCPLineFramer.extractLines(appending: "one\ntwo\nthree", to: &buffer)
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(buffer, "three")
    }

    func testLineFramerSkipsBlankLines() {
        var buffer = ""
        let lines = MCPLineFramer.extractLines(appending: "\n\nreal\n\n", to: &buffer)
        XCTAssertEqual(lines, ["real"])
    }

    // MARK: - MCPJSONRPCCodec.decodeResponse

    func testDecodeResponseParsesWellFormedResult() {
        let decoded = MCPJSONRPCCodec.decodeResponse(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#)
        guard case .result(let id, let value) = decoded else {
            return XCTFail("expected .result, got \(decoded)")
        }
        XCTAssertEqual(id, 3)
        XCTAssertEqual(value, .object(["ok": .bool(true)]))
    }

    func testDecodeResponseParsesWellFormedError() {
        let decoded = MCPJSONRPCCodec.decodeResponse(
            #"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}"#
        )
        XCTAssertEqual(decoded, .error(id: 4, code: -32601, message: "Method not found"))
    }

    func testDecodeResponseTreatsInvalidJSONAsUnrecognizedNotCrash() {
        XCTAssertEqual(MCPJSONRPCCodec.decodeResponse("not json at all {{{"), .unrecognized)
        XCTAssertEqual(MCPJSONRPCCodec.decodeResponse(""), .unrecognized)
        XCTAssertEqual(MCPJSONRPCCodec.decodeResponse("null"), .unrecognized)
    }

    func testDecodeResponseTreatsMissingIDAsUnrecognized() {
        let decoded = MCPJSONRPCCodec.decodeResponse(#"{"jsonrpc":"2.0","method":"notifications/progress"}"#)
        XCTAssertEqual(decoded, .unrecognized)
    }

    func testDecodeResponseTreatsIDWithNoResultOrErrorAsMalformedEnvelope() {
        let decoded = MCPJSONRPCCodec.decodeResponse(#"{"jsonrpc":"2.0","id":7}"#)
        XCTAssertEqual(decoded, .malformedEnvelope(id: 7))
    }

    // MARK: - MCPJSONRPCCodec.toolDescriptors

    func testToolDescriptorsParsesWellFormedList() throws {
        let result: MLXJSONValue = .object([
            "tools": .array([
                .object([
                    "name": .string("read_file"),
                    "description": .string("Reads a file."),
                    "inputSchema": .object(["type": .string("object")])
                ])
            ])
        ])
        let descriptors = try MCPJSONRPCCodec.toolDescriptors(fromToolsListResult: result)
        XCTAssertEqual(descriptors, [
            MCPToolDescriptor(
                name: "read_file",
                description: "Reads a file.",
                inputSchema: .object(["type": .string("object")])
            )
        ])
    }

    func testToolDescriptorsThrowsWhenToolsKeyMissing() {
        XCTAssertThrowsError(try MCPJSONRPCCodec.toolDescriptors(fromToolsListResult: .object(["nope": .bool(true)])))
    }

    func testToolDescriptorsThrowsWhenToolMissingName() {
        let result: MLXJSONValue = .object(["tools": .array([.object(["description": .string("x")])])])
        XCTAssertThrowsError(try MCPJSONRPCCodec.toolDescriptors(fromToolsListResult: result))
    }

    func testToolDescriptorsDefaultsMissingDescriptionAndSchema() throws {
        let result: MLXJSONValue = .object(["tools": .array([.object(["name": .string("noop")])])])
        let descriptors = try MCPJSONRPCCodec.toolDescriptors(fromToolsListResult: result)
        XCTAssertEqual(descriptors.first?.description, "")
        XCTAssertEqual(descriptors.first?.inputSchema, .object([
            "type": .string("object"),
            "properties": .object([:])
        ]))
    }

    // MARK: - MCPJSONRPCCodec.extractText / parseArguments

    func testExtractTextJoinsTextContentParts() throws {
        let result: MLXJSONValue = .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("first")]),
                .object(["type": .string("text"), "text": .string("second")])
            ])
        ])
        XCTAssertEqual(try MCPJSONRPCCodec.extractText(fromToolCallResult: result), "first\nsecond")
    }

    func testExtractTextThrowsOnIsErrorTrue() {
        let result: MLXJSONValue = .object([
            "content": .array([.object(["type": .string("text"), "text": .string("boom")])]),
            "isError": .bool(true)
        ])
        XCTAssertThrowsError(try MCPJSONRPCCodec.extractText(fromToolCallResult: result))
    }

    func testExtractTextThrowsWhenNoTextContent() {
        XCTAssertThrowsError(try MCPJSONRPCCodec.extractText(fromToolCallResult: .object(["content": .array([])])))
    }

    func testParseArgumentsDefaultsToEmptyObjectForNilOrEmpty() throws {
        XCTAssertEqual(try MCPJSONRPCCodec.parseArguments(nil), .object([:]))
        XCTAssertEqual(try MCPJSONRPCCodec.parseArguments(""), .object([:]))
    }

    func testParseArgumentsDecodesValidJSON() throws {
        XCTAssertEqual(
            try MCPJSONRPCCodec.parseArguments(#"{"path":"notes.md"}"#),
            .object(["path": .string("notes.md")])
        )
    }

    // MARK: - MCPToolNameQualifier

    func testQualifyUnqualifyRoundTrip() {
        let qualified = MCPToolNameQualifier.qualify(server: "filesystem", tool: "read_file")
        XCTAssertEqual(qualified, "mcp__filesystem__read_file")
        let parsed = MCPToolNameQualifier.unqualify(qualified)
        XCTAssertEqual(parsed?.server, "filesystem")
        XCTAssertEqual(parsed?.tool, "read_file")
    }

    func testTwoServersWithSameLocalToolNameDoNotCollide() {
        let first = MCPToolNameQualifier.qualify(server: "filesystem", tool: "search")
        let second = MCPToolNameQualifier.qualify(server: "github", tool: "search")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(MCPToolNameQualifier.unqualify(first)?.server, "filesystem")
        XCTAssertEqual(MCPToolNameQualifier.unqualify(second)?.server, "github")
    }

    func testUnqualifyRejectsMalformedNames() {
        XCTAssertNil(MCPToolNameQualifier.unqualify("read_file"))
        XCTAssertNil(MCPToolNameQualifier.unqualify("mcp__nosep"))
        XCTAssertNil(MCPToolNameQualifier.unqualify("mcp____"))
        XCTAssertNil(MCPToolNameQualifier.unqualify("mcp__server__"))
    }

    func testIsValidServerNameRejectsNamesContainingTheSeparator() {
        XCTAssertTrue(MCPToolNameQualifier.isValidServerName("filesystem"))
        XCTAssertFalse(MCPToolNameQualifier.isValidServerName(""))
        XCTAssertFalse(MCPToolNameQualifier.isValidServerName("my__server"))
    }

    // unqualify splits forward, on the first "__" after the prefix. A server
    // name is validated (isValidServerName) to never contain "__", so this
    // is unambiguous for any server actually accepted by configuration --
    // a tool name containing "__" still splits correctly, taking everything
    // after the first "__" as the tool name.
    func testUnqualifySplitsForwardSoToolNamesMayContainTheSeparator() {
        let parsed = MCPToolNameQualifier.unqualify("mcp__filesystem__weird__tool__name")
        XCTAssertEqual(parsed?.server, "filesystem")
        XCTAssertEqual(parsed?.tool, "weird__tool__name")
    }

    // MARK: - Process lifecycle (real subprocesses, no network)

    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake_mcp_server.py")
            .path
    }

    private func fakeServerConfiguration(extraArguments: [String] = []) -> MCPServerConfiguration {
        MCPServerConfiguration(name: "fake", command: "python3", arguments: [fixturePath] + extraArguments)
    }

    @MainActor
    func testConnectionStartsHandshakesAndListsTools() async throws {
        let connection = MCPServerConnection(configuration: fakeServerConfiguration())
        await connection.start()
        XCTAssertEqual(connection.state, .running(toolCount: 1))
        XCTAssertEqual(connection.tools.first?.name, "echo")

        let result = try await connection.callTool(name: "echo", argumentsJSON: #"{"text":"hi"}"#)
        XCTAssertEqual(result, "echo:hi")

        await connection.stop()
    }

    // Regression test for the chunk-ordering race: the fixture deliberately
    // writes one response in two separate stdout writes with a delay between
    // them, forcing two distinct pipe reads. Line reassembly must still
    // produce the exact original response.
    @MainActor
    func testConnectionReassemblesAResponseSplitAcrossTwoStdoutWrites() async throws {
        let connection = MCPServerConnection(
            configuration: fakeServerConfiguration(extraArguments: ["--split-write-tools-call"])
        )
        await connection.start()
        XCTAssertEqual(connection.state, .running(toolCount: 1))

        let result = try await connection.callTool(name: "echo", argumentsJSON: #"{"text":"split-write"}"#)
        XCTAssertEqual(result, "echo:split-write")

        await connection.stop()
    }

    @MainActor
    func testConnectionCrashesQuicklyWhenProcessExitsImmediately() async throws {
        let configuration = MCPServerConfiguration(name: "dead-on-arrival", command: "/bin/sh", arguments: ["-c", "exit 1"])
        let connection = MCPServerConnection(configuration: configuration, requestTimeoutSeconds: 5)
        let start = Date()
        await connection.start()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "should fail via the termination path, not the 5s request timeout")
        guard case .crashed = connection.state else {
            return XCTFail("expected .crashed, got \(connection.state)")
        }
        XCTAssertTrue(connection.tools.isEmpty)
    }

    @MainActor
    func testConnectionCrashesWithinBoundedTimeWhenProcessNeverResponds() async throws {
        let configuration = MCPServerConfiguration(name: "silent", command: "/bin/sh", arguments: ["-c", "sleep 30"])
        let connection = MCPServerConnection(configuration: configuration, requestTimeoutSeconds: 0.3)
        let start = Date()
        await connection.start()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard case .crashed = connection.state else {
            return XCTFail("expected .crashed, got \(connection.state)")
        }
        await connection.stop()
    }

    @MainActor
    func testConnectionReportsEmptyToolListAsRunningNotCrashed() async throws {
        let connection = MCPServerConnection(configuration: fakeServerConfiguration(extraArguments: ["--empty-tools"]))
        await connection.start()
        XCTAssertEqual(connection.state, .running(toolCount: 0))
        XCTAssertTrue(connection.tools.isEmpty)
        await connection.stop()
        XCTAssertEqual(connection.state, .stopped)
    }

    @MainActor
    func testConnectionCrashesOnMalformedToolsListInsteadOfHanging() async throws {
        let connection = MCPServerConnection(
            configuration: fakeServerConfiguration(extraArguments: ["--malformed-tools-list"]),
            requestTimeoutSeconds: 5
        )
        let start = Date()
        await connection.start()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        guard case .crashed = connection.state else {
            return XCTFail("expected .crashed, got \(connection.state)")
        }
        await connection.stop()
    }

    // Regression test: a pending tool call used to hang until the full
    // request timeout elapsed when the server process died mid-call.
    @MainActor
    func testCallFailsQuicklyWhenServerDiesMidCall() async throws {
        let connection = MCPServerConnection(
            configuration: fakeServerConfiguration(extraArguments: ["--die-on-call"]),
            requestTimeoutSeconds: 10
        )
        await connection.start()
        XCTAssertEqual(connection.state, .running(toolCount: 1))

        let start = Date()
        do {
            _ = try await connection.callTool(name: "echo", argumentsJSON: #"{"text":"hi"}"#)
            XCTFail("expected the call to fail")
        } catch let error as MCPClientError {
            guard case .processUnavailable = error else {
                return XCTFail("expected .processUnavailable, got \(error)")
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            3,
            "a dead server should fail the pending call promptly, not after the full 10s request timeout"
        )
        guard case .crashed = connection.state else {
            return XCTFail("expected .crashed after the process died, got \(connection.state)")
        }
    }

    @MainActor
    func testCallAgainstAlreadyStoppedServerFailsCleanly() async throws {
        let connection = MCPServerConnection(configuration: fakeServerConfiguration())
        await connection.start()
        await connection.stop()

        do {
            _ = try await connection.callTool(name: "echo", argumentsJSON: nil)
            XCTFail("expected the call to fail")
        } catch let error as MCPClientError {
            guard case .processUnavailable = error else {
                return XCTFail("expected .processUnavailable, got \(error)")
            }
        }
    }
}
