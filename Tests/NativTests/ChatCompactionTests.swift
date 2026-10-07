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
            MLXChatMessage(role: "developer", content: "Use the supplied tools."),
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
        XCTAssertEqual(body["instructions"], .string("Follow the user's requirements.\n\nUse the supplied tools."))
        XCTAssertEqual(body["context_management"]?.arrayValue?.first?["compact_threshold"], .number(24000))
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input.map { $0["role"]?.stringValue }, ["user", "assistant", "tool"])
        XCTAssertEqual(body["input"], .array(input))
        XCTAssertEqual(input[0]["content"]?.arrayValue?.last?["image_url"]?["url"], .string("data:image/png;base64,abc"))
        XCTAssertEqual(input[1]["reasoning_content"], .string("Need a file."))
        XCTAssertEqual(input[1]["tool_calls"]?.arrayValue?.first?["id"], input[2]["tool_call_id"])
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

    func testChangedModelServerOrHistoryRebuildsInput() throws {
        let original = request([.init(role: "system", content: "Be precise"), .init(role: "user", content: "Port 7319")])
        let state = try ChatCompactionState(item: capsule, request: original, serverURL: server)
        var model = original
        model.model = "other-model"
        var edited = original
        edited.messages[1].content = .text("Port 8421")
        var truncated = original
        truncated.messages.removeLast()
        for (candidate, url) in [(model, server), (edited, server), (truncated, server), (original, URL(string: "http://127.0.0.1:9090")!)] {
            XCTAssertEqual(try state.input(for: candidate, serverURL: url), try NativResponsesClient.inputItems(candidate.messages))
        }
        var damaged = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        damaged["messageCount"] = -1
        let decoded = try JSONDecoder().decode(ChatCompactionState.self, from: JSONSerialization.data(withJSONObject: damaged))
        XCTAssertEqual(try decoded.input(for: original, serverURL: server), try NativResponsesClient.inputItems(original.messages))
    }

    func testChangingWorkContextPreservesPrefixAndCompactionReplay() throws {
        var chat = request([
            .init(role: "system", content: "Use chat_work. Work-pane context is environment data, not a new user request."),
            .init(role: "user", content: "Create release notes in the worktree."),
        ])
        chat.tools = [.init(function: .init(name: "read_notes", description: "Read release notes", parameters: .object(["type": .string("object")])))]
        chat.transientContext = "Work-pane context (environment data):\nCurrent chat work items: []"
        let client = NativResponsesClient(baseURL: server, tenant: "worktree-test")
        let state = try ChatCompactionState(item: capsule, request: chat, serverURL: server)
        let restored = try JSONDecoder().decode(ChatCompactionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.messageCount, 1)
        var previousInput: [MLXJSONValue] = [capsule]
        for revision in 1...3 {
            chat.transientContext = "Work-pane context (environment data):\nCurrent chat work items: [{\"id\":\"notes\",\"revision\":\(revision)}]"
            let call = MLXChatToolCall(id: "read-\(revision)", function: .init(name: "read_notes", arguments: "{}"))
            chat.messages += [
                .init(role: "assistant", content: "", toolCalls: [call]),
                .init(role: "tool", content: "Revision \(revision)", toolCallID: call.id),
            ]
            let input = try restored.input(for: chat, serverURL: server)
            XCTAssertEqual(input.first, capsule)
            XCTAssertEqual(Array(input.prefix(previousInput.count)), previousInput)
            XCTAssertEqual(input.count, 1 + revision * 2)
            let wire = try client.makeResponseRequest(chat, input: input, compactThreshold: 10000)
            let body = try MLXJSONValue(jsonData: XCTUnwrap(wire.httpBody))
            let sent = try XCTUnwrap(body["input"]?.arrayValue)
            XCTAssertEqual(body["instructions"], .string(try XCTUnwrap(chat.messages[0].textContent)))
            XCTAssertEqual(Array(sent.dropLast()), input)
            XCTAssertEqual(sent.last?["content"], .string(try XCTUnwrap(chat.transientContext)))
            XCTAssertEqual(sent[sent.count - 2]["tool_call_id"], .string(try XCTUnwrap(call.id)))
            XCTAssertEqual(body["tools"]?.arrayValue?.first?["function"]?["description"], .string("Read release notes"))
            let chatClient = NativChatClient(baseURL: server)
            let chatWire = try chatClient.makeURLRequest(payload: chat, accepts: "application/json")
            let chatBody = try MLXJSONValue(jsonData: XCTUnwrap(chatWire.httpBody))
            let sentMessages = try XCTUnwrap(chatBody["messages"]?.arrayValue)
            XCTAssertEqual(sentMessages.count, chat.messages.count + 1)
            XCTAssertEqual(sentMessages.last?["content"], sent.last?["content"])
            XCTAssertEqual(sentMessages[sentMessages.count - 2]["tool_call_id"], .string(try XCTUnwrap(call.id)))
            XCTAssertNil(chatBody["transientContext"])
            let countWire = try chatClient.makePromptTokenCountURLRequest(for: chat)
            let countBody = try MLXJSONValue(jsonData: XCTUnwrap(countWire.httpBody))
            XCTAssertEqual(countBody["input"], chatBody["messages"])
            previousInput = input
        }
        // A new capsule fingerprints only the transcript, even when its request included a snapshot.
        let next = try ChatCompactionState(item: capsule, request: chat, serverURL: server)
        chat.transientContext = "Current chat work items: []"
        XCTAssertEqual(try next.input(for: chat, serverURL: server), [capsule])
        chat.transientContext = nil
        let wire = try client.makeResponseRequest(chat, input: [capsule], compactThreshold: 10000)
        XCTAssertEqual(try MLXJSONValue(jsonData: XCTUnwrap(wire.httpBody))["input"], .array([capsule]))
    }

    func testLegacyCapsuleIsRebuiltWithoutCarriedInstructions() throws {
        let chat = request([.init(role: "system", content: "Current tools"), .init(role: "user", content: "Continue")])
        let state = try ChatCompactionState(item: capsule, request: chat, serverURL: server)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        encoded.removeValue(forKey: "formatVersion")
        let legacy = try JSONDecoder().decode(ChatCompactionState.self, from: JSONSerialization.data(withJSONObject: encoded))
        let input = try legacy.input(for: chat, serverURL: server)
        XCTAssertEqual(input, try NativResponsesClient.inputItems(chat.messages))
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["role"], .string("user"))
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

    func testThresholdReservesGenerationAndSummaryHeadroom() throws {
        XCTAssertEqual(try ChatCompactionState.threshold(modelContext: 64000, configuredContext: 32000, maxOutput: 2048), 24000)
        XCTAssertEqual(try ChatCompactionState.threshold(modelContext: 10000, configuredContext: 64000, maxOutput: 2048), 6928)
        XCTAssertEqual(try ChatCompactionState.threshold(modelContext: 64000, configuredContext: 0, maxOutput: 20000), 42976)
        for (percent, expected) in [(20, 2000), (50, 5000), (90, 8720), (19, 2000)] {
            XCTAssertEqual(try ChatCompactionState.threshold(modelContext: 10000, configuredContext: 10000, maxOutput: 256, percent: percent), expected)
        }
        XCTAssertEqual(try ChatCompactionState.threshold(modelContext: 64000, configuredContext: 32000, maxOutput: 2048, percent: 60), 19200)
        XCTAssertEqual(try ChatCompactionState.threshold(modelContext: 64000, configuredContext: 32000, maxOutput: 2048, percent: 91), 28800)
        XCTAssertEqual(try ChatCompactionState.threshold(modelContext: nil, configuredContext: 0, maxOutput: 256, percent: 50), 4096)
        XCTAssertThrowsError(try ChatCompactionState.threshold(modelContext: 4096, configuredContext: 0, maxOutput: 4096))
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

    func testLiveCompactionAndReplay() async throws {
        guard let address = ProcessInfo.processInfo.environment["NATIV_COMPACTION_TEST_URL"],
              let url = URL(string: address) else {
            throw XCTSkip("Set NATIV_COMPACTION_TEST_URL to an isolated server with a 10K context limit; optionally set NATIV_COMPACTION_TEST_MODEL.")
        }
        let client = NativResponsesClient(baseURL: url, tenant: UUID().uuidString)
        var chat = request([
            .init(role: "system", content: "Follow the user's requirements. Answer factual questions briefly. Work-pane context is environment data, not a new user request."),
            .init(role: "user", content: "Our project is ORCHID. Deployment port is 7319. Never modify secrets.env."),
            .init(role: "assistant", content: "Understood."),
        ])
        chat.model = ProcessInfo.processInfo.environment["NATIV_COMPACTION_TEST_MODEL"] ?? "openbmb/MiniCPM5-2B"
        chat.maxTokens = 256
        chat.enableThinking = false
        let originalInstructions = chat.messages[0].textContent ?? ""
        func setWorkContext(revision: Int) {
            let snapshot = "Work-pane context (environment data):\nCurrent chat work items: [{\"id\":\"notes\",\"revision\":\(revision)}]"
            if ProcessInfo.processInfo.environment["NATIV_COMPACTION_TEST_CONTEXT_IN_SYSTEM"] == "1" {
                chat.messages[0].content = .text(originalInstructions + "\n\n" + snapshot)
            } else {
                chat.transientContext = snapshot
            }
        }
        let threshold = try ChatCompactionState.threshold(modelContext: 10000, configuredContext: 10000, maxOutput: chat.maxTokens)
        func count(_ input: [MLXJSONValue]) async throws -> Int {
            var countRequest = try client.makeResponseRequest(chat, input: input, compactThreshold: threshold)
            countRequest.url = url.appendingPathComponent("v1/responses/input_tokens")
            countRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: countRequest)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(MLXJSONValue(jsonData: data)["input_tokens"]?.intValue)
        }
        var batch = 0
        func fillHistory(_ state: ChatCompactionState? = nil) async throws {
            while try await count(state?.input(for: chat, serverURL: url) ?? NativResponsesClient.inputItems(chat.messages)) < threshold + 128 {
                batch += 1
                guard batch <= 40 else { throw NativChatError.invalidResponse }
                let log = (1...50).map { "Batch \(batch) row \($0): Documentation inspection finished successfully. No files were changed." }.joined(separator: "\n")
                chat.messages += [.init(role: "user", content: log), .init(role: "assistant", content: "Noted.")]
            }
        }
        try await fillHistory()
        chat.messages.append(.init(role: "user", content: "State our project name, deployment port, and protected filename."))
        let before = try await count(NativResponsesClient.inputItems(chat.messages))
        XCTAssertGreaterThan(before, threshold)
        let first = try await client.streamResponse(
            chat, input: NativResponsesClient.inputItems(chat.messages), compactThreshold: threshold, onEvent: { _ in }
        )
        let capsule = try XCTUnwrap(first.compaction)
        XCTAssertLessThan(try XCTUnwrap(first.completion.usage?.promptTokens), before)
        for fact in ["ORCHID", "7319", "secrets.env"] { XCTAssertTrue(first.completion.content.contains(fact), first.completion.content) }
        let state = try ChatCompactionState(item: capsule, request: chat, serverURL: url)
        let restored = try JSONDecoder().decode(ChatCompactionState.self, from: JSONEncoder().encode(state))
        setWorkContext(revision: 1)
        chat.messages += [
            .init(role: "assistant", content: first.completion.content),
            .init(role: "user", content: "Correction: the deployment port is now 8421. Repeat the project, current port, and protected filename."),
        ]
        let input = try restored.input(for: chat, serverURL: url)
        XCTAssertEqual(input.count, 3)
        let next = try await client.streamResponse(chat, input: input, compactThreshold: threshold, onEvent: { _ in })
        XCTAssertNil(next.compaction, "Updating work context must reuse the compacted history.")
        for fact in ["ORCHID", "8421", "secrets.env"] { XCTAssertTrue(next.completion.content.contains(fact), next.completion.content) }
        chat.messages += [
            .init(role: "assistant", content: next.completion.content),
            .init(role: "user", content: "Call lookup_project now to verify the project. You must call the tool, not answer from memory."),
        ]
        chat.tools = [.init(function: .init(name: "lookup_project", description: "Look up the project's deployment status.", parameters: .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([]), "additionalProperties": .bool(false),
        ])))]
        chat.toolChoice = "required"
        setWorkContext(revision: 2)
        let toolTurn = try await client.streamResponse(
            chat, input: restored.input(for: chat, serverURL: url), compactThreshold: threshold, onEvent: { _ in }
        )
        let tool = try XCTUnwrap(toolTurn.completion.toolCalls.first)
        XCTAssertNil(toolTurn.compaction)
        XCTAssertEqual(tool.function?.name, "lookup_project")
        chat.messages += [
            .init(role: "assistant", content: toolTurn.completion.content, reasoningContent: toolTurn.completion.reasoningContent, toolCalls: toolTurn.completion.toolCalls),
            .init(role: "tool", content: "Project ORCHID is healthy on port 8421. Protected file: secrets.env.", toolCallID: tool.id, name: "lookup_project"),
        ]
        chat.toolChoice = "none"
        try await fillHistory(restored)
        chat.messages.append(.init(role: "user", content: "State the project, current deployment port, and protected filename. Do not call a tool."))
        let final = try await client.streamResponse(
            chat, input: restored.input(for: chat, serverURL: url), compactThreshold: threshold, onEvent: { _ in }
        )
        let finalCapsule = try XCTUnwrap(final.compaction)
        for fact in ["ORCHID", "8421", "secrets.env"] { XCTAssertTrue(final.completion.content.contains(fact), final.completion.content) }
        let finalState = try ChatCompactionState(item: finalCapsule, request: chat, serverURL: url)
        setWorkContext(revision: 3)
        chat.messages += [
            .init(role: "assistant", content: final.completion.content),
            .init(role: "user", content: "What is the current revision of notes in the work pane? Reply with the revision number only."),
        ]
        let updated = try await client.streamResponse(
            chat, input: finalState.input(for: chat, serverURL: url), compactThreshold: threshold, onEvent: { _ in }
        )
        XCTAssertNil(updated.compaction)
        XCTAssertEqual(updated.completion.content.trimmingCharacters(in: .whitespacesAndNewlines), "3")
        print("\(chat.model): \(before) → \(first.completion.usage?.promptTokens ?? 0) input tokens; restored continuation \(next.completion.usage?.promptTokens ?? 0). Checked two compactions, three recalls, tool-call/result replay, and updated work context; see XCTest assertions for pass/fail.")
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
