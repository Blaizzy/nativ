import XCTest
@testable import NativServerKit

final class ChatCompactionTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:8080")!
    private let capsule: MLXJSONValue = .object([
        "id": .string("compact-1"), "type": .string("compaction"), "encrypted_content": .string("opaque"),
    ])

    private func request(_ messages: [MLXChatMessage]) -> MLXChatCompletionRequest {
        MLXChatCompletionRequest(
            model: "test-model", messages: messages, maxTokens: 1024,
            temperature: 0, topK: 0, topP: 1, minP: 0
        )
    }

    func testWireRequestPreservesImagesReasoningToolPairsAndSampling() throws {
        let call = MLXChatToolCall(id: "call-1", function: .init(name: "read", arguments: "{}"))
        let messages = [
            MLXChatMessage(role: "system", content: "Follow the user's requirements."),
            MLXChatMessage(role: "user", content: .parts([.init(text: "Describe"), .init(imageURL: "data:image/png;base64,abc")])),
            MLXChatMessage(role: "assistant", content: "", reasoningContent: "Need a file.", toolCalls: [call]),
            MLXChatMessage(role: "tool", content: "file contents", toolCallID: "call-1", name: "read"),
        ]
        var chat = request(messages)
        chat.tools = [.init(function: .init(name: "read", description: "Read a file", parameters: .object(["type": .string("object")])))]
        chat.enableThinking = false
        let client = NativResponsesClient(baseURL: server, apiKey: "test-key", tenant: "session-1")
        let input = try NativResponsesClient.inputItems(messages)
        let wire = try client.makeResponseRequest(chat, input: input, compactThreshold: 24000)
        let body = try MLXJSONValue(jsonData: XCTUnwrap(wire.httpBody))
        XCTAssertEqual(wire.url?.path, "/v1/responses")
        XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(wire.value(forHTTPHeaderField: "X-APC-Tenant"), "session-1")
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_output_tokens"], .number(1024))
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["enable_thinking"], .bool(false))
        XCTAssertEqual(body["context_management"]?.arrayValue?.first?["compact_threshold"], .number(24000))
        XCTAssertEqual(input[1]["content"]?.arrayValue?.last?["image_url"]?["url"], .string("data:image/png;base64,abc"))
        XCTAssertEqual(input[2]["reasoning_content"], .string("Need a file."))
        XCTAssertEqual(input[2]["tool_calls"]?.arrayValue?.first?["id"], input[3]["tool_call_id"])
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["function"]?["name"], .string("read"))
    }

    func testStreamUsesCompletedOutputAndCarriesCapsule() throws {
        var stream = MLXResponseStream()
        let delta = try stream.consume(#"{"type":"response.output_text.delta","delta":"Hello","timings":{"predicted_per_second":42}}"#)
        XCTAssertEqual(delta?.content, "Hello")
        XCTAssertEqual(delta?.decodeTokensPerSecond, 42)
        let reasoning = try stream.consume(#"{"type":"response.reasoning_text.delta","delta":"Check facts"}"#)
        XCTAssertEqual(reasoning?.reasoningContent, "Check facts")
        let output: [MLXJSONValue] = [capsule,
            .object(["type": .string("reasoning"), "summary": .array([.object(["type": .string("summary_text"), "text": .string("Check facts")])])]),
            .object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string("Hello")])])]),
            .object(["type": .string("function_call"), "call_id": .string("call-1"), "name": .string("read"), "arguments": .string("{}")]),
        ]
        let done = MLXJSONValue.object([
            "type": .string("response.completed"),
            "response": .object([
                "status": .string("completed"), "output": .array(output),
                "usage": .object(["input_tokens": .number(1000), "output_tokens": .number(20), "total_tokens": .number(1020)]),
            ]),
        ])
        _ = try stream.consume(String(decoding: JSONEncoder().encode(done), as: UTF8.self))
        let result = try stream.result(elapsed: 1)
        XCTAssertEqual(result.compaction, capsule)
        XCTAssertEqual(result.completion.content, "Hello")
        XCTAssertEqual(result.completion.reasoningContent, "Check facts")
        XCTAssertEqual(result.completion.toolCalls.first?.id, "call-1")
        XCTAssertEqual(result.completion.finishReason, "tool_calls")
        XCTAssertEqual(result.completion.usage?.promptTokens, 1000)
        XCTAssertEqual(result.completion.usage?.completionTokens, 20)
        let measured = try stream.result(elapsed: 1, inputTokensBeforeCompaction: 8000)
        XCTAssertEqual(measured.inputTokensBeforeCompaction, 8000)
    }

    func testFailedOrUnfinishedStreamCannotCommitCompaction() throws {
        for event in [
            #"{"type":"error","message":"Summary failed"}"#,
            #"{"type":"response.failed","response":{"error":{"message":"Generation failed"}}}"#,
        ] {
            var stream = MLXResponseStream()
            XCTAssertThrowsError(try stream.consume(event))
            XCTAssertThrowsError(try stream.result(elapsed: 1))
        }
        var unfinished = MLXResponseStream()
        _ = try unfinished.consume(#"{"type":"response.output_text.delta","delta":"Partial"}"#)
        XCTAssertThrowsError(try unfinished.result(elapsed: 1))
        _ = try unfinished.consume(#"{"type":"response.completed","response":{"output":[{"type":"compaction","encrypted_content":"opaque"}]}}"#)
        XCTAssertThrowsError(try unfinished.result(elapsed: 1))
    }

    func testContextLimitedResponsePreservesPartialAnswerAndReportsLength() throws {
        var stream = MLXResponseStream()
        _ = try stream.consume(#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"1 2 3"}]}],"usage":{"input_tokens":4064,"output_tokens":32,"total_tokens":4096}}}"#)
        let result = try stream.result(elapsed: 1)
        XCTAssertEqual(result.completion.content, "1 2 3")
        XCTAssertEqual(result.completion.finishReason, "length")
        XCTAssertEqual(result.completion.usage?.totalTokens, 4096)
    }

    func testReplayReplacesCoveredPrefixAndPreservesNewToolResult() throws {
        let call = MLXChatToolCall(id: "c1", function: .init(name: "read", arguments: "{}"))
        let original = request([.init(role: "user", content: "Read the file")])
        let state = try ChatCompactionState(item: capsule, request: original, serverURL: server)
        var next = original
        next.messages += [
            .init(role: "assistant", content: "", toolCalls: [call]),
            .init(role: "tool", content: "data", toolCallID: "c1"),
        ]
        let input = try state.input(for: next, serverURL: server)
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input.first, capsule)
        XCTAssertEqual(input.last?["tool_call_id"], .string("c1"))
        let second = try ChatCompactionState(item: .object(["type": .string("compaction"), "encrypted_content": .string("second")]), request: next, serverURL: server)
        next.messages.append(.init(role: "user", content: "Continue"))
        let recompacted = try second.input(for: next, serverURL: server)
        XCTAssertEqual(recompacted.count, 2)
        XCTAssertEqual(recompacted.first?["encrypted_content"], .string("second"))
        XCTAssertEqual(recompacted.last?["content"], .string("Continue"))
    }

    func testChangedScopeOrHistoryRebuildsInput() throws {
        let original = request([.init(role: "system", content: "Be precise"), .init(role: "user", content: "Port 7319")])
        let state = try ChatCompactionState(item: capsule, request: original, serverURL: server)
        var model = original
        model.model = "other-model"
        var edited = original
        edited.messages[1].content = .text("Port 8421")
        var system = original
        system.messages[0].content = .text("New instructions")
        var truncated = original
        truncated.messages.removeLast()
        for (candidate, url) in [(model, server), (edited, server), (system, server), (truncated, server), (original, URL(string: "http://127.0.0.1:9090")!)] {
            XCTAssertEqual(try state.input(for: candidate, serverURL: url), try NativResponsesClient.inputItems(candidate.messages))
        }
        var damaged = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        damaged["messageCount"] = -1
        let decoded = try JSONDecoder().decode(ChatCompactionState.self, from: JSONSerialization.data(withJSONObject: damaged))
        XCTAssertEqual(try decoded.input(for: original, serverURL: server), try NativResponsesClient.inputItems(original.messages))
    }

    func testSessionPersistsCapsuleWithoutReplacingTranscriptAndLoadsLegacyJSON() throws {
        var answer = ChatTranscriptMessage(role: .assistant, content: "Project ORCHID")
        answer.compactionMetrics = .init(inputTokensBefore: 8000, inputTokensAfter: 2000)
        answer.isCompacting = true
        let restored = try JSONDecoder().decode(ChatTranscriptMessage.self, from: JSONEncoder().encode(answer))
        XCTAssertFalse(restored.isCompacting)
        XCTAssertEqual(restored.compactionMetrics, answer.compactionMetrics)
        XCTAssertEqual(restored.apiMessage?.content, answer.apiMessage?.content)
        let messages = [ChatTranscriptMessage(role: .user, content: "Keep this visible"), restored]
        var session = ChatSession(id: UUID(), title: "test", createdAt: Date(), updatedAt: Date(), messages: messages)
        session.compaction = try ChatCompactionState(item: capsule, request: request(messages.compactMap(\.apiMessage)), serverURL: server)
        let encoded = try JSONEncoder().encode(session)
        let loaded = try JSONDecoder().decode(ChatSession.self, from: encoded)
        XCTAssertEqual(loaded.compaction, session.compaction)
        XCTAssertEqual(loaded.messages, messages)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "compaction")
        let old = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.compaction)
        XCTAssertEqual(old.messages, messages)
    }

    func testThresholdUsesEffectiveContextAndSelectedPercentage() {
        for (model, configured, expected) in [
            (64000, 32000, 24000), (10000, 64000, 7500),
            (64000, 0, 48000), (128000, 2048, 1536), (1, 0, 1),
        ] {
            XCTAssertEqual(ChatCompactionState.threshold(modelContext: model, configuredContext: configured), expected)
        }
        for (percent, expected) in [(19, 2000), (20, 2000), (50, 5000), (75, 7500), (90, 9000), (91, 9000)] {
            XCTAssertEqual(ChatCompactionState.threshold(modelContext: 10000, configuredContext: 10000, percent: percent), expected)
        }
        XCTAssertEqual(ChatCompactionState.threshold(modelContext: nil, configuredContext: 0), 6144)
    }

    func testLegacyMaxOutputIsPreservedAndDoesNotAdvanceCompaction() throws {
        let client = NativResponsesClient(baseURL: server, tenant: "issue-670")
        for context in [2048, 4096, 8192, 128000] {
            for output in [2048, context, context * 2] {
                let legacyJSON = "{\"maxTokens\":\(output),\"maxKVSize\":\(context)}"
                let settings = try JSONDecoder().decode(NativSettings.self, from: Data(legacyJSON.utf8))
                XCTAssertTrue(settings.compactionEnabled)
                for thinking in [false, true] {
                    var chat = request([.init(role: "user", content: "Are you ready to help me with some coding?")])
                    chat.maxTokens = settings.maxTokens
                    chat.enableThinking = thinking
                    let threshold = ChatCompactionState.threshold(
                        modelContext: 128000, configuredContext: settings.maxKVSize,
                        percent: settings.compactionThresholdPercent
                    )
                    let wire = try client.makeResponseRequest(
                        chat, input: NativResponsesClient.inputItems(chat.messages), compactThreshold: threshold
                    )
                    let body = try MLXJSONValue(jsonData: XCTUnwrap(wire.httpBody))
                    XCTAssertEqual(body["max_output_tokens"], .number(Double(output)))
                    XCTAssertEqual(body["context_management"]?.arrayValue?.first?["compact_threshold"], .number(Double(context * 3 / 4)))
                    XCTAssertEqual(body["enable_thinking"], .bool(thinking))
                }
                XCTAssertEqual(settings.maxTokens, output)
                XCTAssertEqual(settings.maxKVSize, context)
            }
        }
    }

    func testCompactionSettingDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(NativSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.compactionEnabled)
        XCTAssertEqual(legacy.compactionThresholdPercent, 75)
        var settings = legacy
        settings.compactionEnabled = false
        settings.compactionThresholdPercent = 50
        let saved = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(NativSettings.self, from: saved)
        XCTAssertFalse(restored.compactionEnabled)
        XCTAssertEqual(restored.compactionThresholdPercent, 50)
        XCTAssertTrue(settings.hasSameLaunchConfiguration(as: legacy))
        for (percent, expected) in [(-10, 20), (19, 20), (20, 20), (50, 50), (90, 90), (91, 90), (200, 90)] {
            settings.compactionThresholdPercent = percent
            XCTAssertEqual(settings.normalized().compactionThresholdPercent, expected)
        }
    }

    func testHTTPStreamAndContextLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompactionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = NativResponsesClient(baseURL: server, tenant: "chat-test", session: session)
        let contextLimit = try await client.contextLimit(for: "test-model")
        XCTAssertEqual(contextLimit, 10000)
        let otherLimit = try await client.contextLimit(for: "another-model")
        XCTAssertNil(otherLimit)
        let chat = request([.init(role: "user", content: "Hello")])
        let progress = CompactionProgressRecorder()
        let response = try await client.streamResponse(
            chat, input: NativResponsesClient.inputItems(chat.messages), compactThreshold: 24000,
            onCompaction: { await progress.record($0) },
            onEvent: { _ in }
        )
        XCTAssertEqual(response.completion.content, "Hello")
        XCTAssertNotNil(response.compaction)
        XCTAssertEqual(response.inputTokensBeforeCompaction, 25000)
        let recorded = await progress.tokens
        XCTAssertEqual(recorded, [25000])
        for (path, threshold) in [("", 30000), ("uncounted", 24000)] {
            let observation = CompactionProgressRecorder()
            let optionalCountClient = NativResponsesClient(
                baseURL: path.isEmpty ? server : server.appendingPathComponent(path),
                tenant: "chat-test", session: session
            )
            let result = try await optionalCountClient.streamResponse(
                chat, input: NativResponsesClient.inputItems(chat.messages), compactThreshold: threshold,
                onCompaction: { await observation.record($0) }, onEvent: { _ in }
            )
            XCTAssertEqual(result.completion.content, "Hello")
            let events = await observation.tokens
            XCTAssertTrue(events.isEmpty)
            if !path.isEmpty { XCTAssertNil(result.inputTokensBeforeCompaction) }
        }
        let oldClient = NativResponsesClient(baseURL: server.appendingPathComponent("old"), tenant: "chat-test", session: session)
        do {
            _ = try await oldClient.streamResponse(
                chat, input: NativResponsesClient.inputItems(chat.messages), compactThreshold: 24000,
                onEvent: { _ in }
            )
            XCTFail("Unsupported Responses requests must fail without a Chat Completions fallback.")
        } catch NativChatError.httpStatus(let status, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testLiveMiniCPMCompactionAndReplay() async throws {
        guard let address = ProcessInfo.processInfo.environment["NATIV_COMPACTION_TEST_URL"],
              let url = URL(string: address) else {
            throw XCTSkip("Set NATIV_COMPACTION_TEST_URL to an isolated MiniCPM server with a 10K context limit.")
        }
        let client = NativResponsesClient(baseURL: url, tenant: UUID().uuidString)
        var chat = request([
            .init(role: "system", content: "Follow the user's requirements. Answer factual questions briefly."),
            .init(role: "user", content: "Our project is ORCHID. Deployment port is 7319. Never modify secrets.env."),
            .init(role: "assistant", content: "Understood."),
        ])
        chat.model = "openbmb/MiniCPM5-2B"
        chat.maxTokens = 256
        chat.enableThinking = false
        let threshold = ChatCompactionState.threshold(modelContext: 10000, configuredContext: 10000)
        for batch in 1...9 {
            let log = (1...50).map { "Batch \(batch) row \($0): Documentation inspection finished successfully. No files were changed." }.joined(separator: "\n")
            chat.messages += [.init(role: "user", content: log), .init(role: "assistant", content: "Noted.")]
        }
        chat.messages.append(.init(role: "user", content: "State our project name, deployment port, and protected filename."))
        var countRequest = URLRequest(url: url.appendingPathComponent("v1/responses/input_tokens"))
        countRequest.httpMethod = "POST"
        countRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        countRequest.httpBody = try JSONEncoder().encode(MLXJSONValue.object([
            "model": .string(chat.model), "enable_thinking": .bool(false),
            "input": .array(try NativResponsesClient.inputItems(chat.messages)),
        ]))
        let (countData, _) = try await URLSession.shared.data(for: countRequest)
        let before = try XCTUnwrap(MLXJSONValue(jsonData: countData)["input_tokens"]?.intValue)
        XCTAssertGreaterThan(before, threshold)
        let first = try await client.streamResponse(
            chat, input: NativResponsesClient.inputItems(chat.messages), compactThreshold: threshold, onEvent: { _ in }
        )
        let capsule = try XCTUnwrap(first.compaction)
        XCTAssertLessThan(try XCTUnwrap(first.completion.usage?.promptTokens), before)
        for fact in ["ORCHID", "7319", "secrets.env"] { XCTAssertTrue(first.completion.content.contains(fact), first.completion.content) }
        let state = try ChatCompactionState(item: capsule, request: chat, serverURL: url)
        let restored = try JSONDecoder().decode(ChatCompactionState.self, from: JSONEncoder().encode(state))
        chat.messages += [
            .init(role: "assistant", content: first.completion.content),
            .init(role: "user", content: "Correction: the deployment port is now 8421. Repeat the project, current port, and protected filename."),
        ]
        let input = try restored.input(for: chat, serverURL: url)
        XCTAssertEqual(input.count, 3)
        let next = try await client.streamResponse(chat, input: input, compactThreshold: threshold, onEvent: { _ in })
        for fact in ["ORCHID", "8421", "secrets.env"] { XCTAssertTrue(next.completion.content.contains(fact), next.completion.content) }
        chat.messages += [
            .init(role: "assistant", content: next.completion.content),
            .init(role: "user", content: "Call lookup_project now to verify the project. You must call the tool, not answer from memory."),
        ]
        chat.tools = [.init(function: .init(name: "lookup_project", description: "Look up the project's deployment status.", parameters: .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([]), "additionalProperties": .bool(false),
        ])))]
        chat.toolChoice = "required"
        let toolTurn = try await client.streamResponse(
            chat, input: restored.input(for: chat, serverURL: url), compactThreshold: threshold, onEvent: { _ in }
        )
        let tool = try XCTUnwrap(toolTurn.completion.toolCalls.first)
        XCTAssertEqual(tool.function?.name, "lookup_project")
        chat.messages += [
            .init(role: "assistant", content: toolTurn.completion.content, reasoningContent: toolTurn.completion.reasoningContent, toolCalls: toolTurn.completion.toolCalls),
            .init(role: "tool", content: "Project ORCHID is healthy on port 8421. Protected file: secrets.env.", toolCallID: tool.id, name: "lookup_project"),
        ]
        for batch in 10...16 {
            let log = (1...50).map { "Batch \(batch) row \($0): Documentation inspection finished successfully. No files were changed." }.joined(separator: "\n")
            chat.messages += [.init(role: "user", content: log), .init(role: "assistant", content: "Noted.")]
        }
        chat.messages.append(.init(role: "user", content: "State the project, current deployment port, and protected filename. Do not call a tool."))
        chat.toolChoice = "none"
        let final = try await client.streamResponse(
            chat, input: restored.input(for: chat, serverURL: url), compactThreshold: threshold, onEvent: { _ in }
        )
        _ = try XCTUnwrap(final.compaction)
        for fact in ["ORCHID", "8421", "secrets.env"] { XCTAssertTrue(final.completion.content.contains(fact), final.completion.content) }
        print("MiniCPM: \(before) → \(first.completion.usage?.promptTokens ?? 0) input tokens; restored continuation \(next.completion.usage?.promptTokens ?? 0). Two compactions, three recall checks, and tool-call/result replay passed.")
    }
}

private actor CompactionProgressRecorder {
    private(set) var tokens: [Int] = []
    func record(_ value: Int) { tokens.append(value) }
}

private final class CompactionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body: String
        let contentType: String
        if request.url!.path.hasPrefix("/old/") || request.url!.path == "/uncounted/v1/responses/input_tokens" {
            body = #"{"detail":"Not Found"}"#
            contentType = "application/json"
        } else if request.url!.path == "/v1/responses/input_tokens" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-APC-Tenant"), "chat-test")
            body = #"{"input_tokens":25000}"#
            contentType = "application/json"
        } else if request.url!.path == "/health" {
            body = #"{"loaded_model":"test-model","effective_context_limit":10000}"#
            contentType = "application/json"
        } else {
            body = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"Hello"}

            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"compaction","encrypted_content":"opaque"},{"type":"message","content":[{"type":"output_text","text":"Hello"}]}]}}


            """
            contentType = "text/event-stream"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: body == #"{"detail":"Not Found"}"# ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
