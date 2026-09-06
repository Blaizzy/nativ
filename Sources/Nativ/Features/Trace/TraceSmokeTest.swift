import Foundation
import NativTrace

/// Exercises the whole trace pipeline inside the built app.
///
/// The unit suite covers each stage against the framework directly. This runs
/// the stages the way the app wires them — real store on disk, real recorder,
/// real queue, real fold — and is what catches an integration mistake that
/// per-stage tests cannot see: a producer writing a scope the reducer does not
/// group, or a payload the resolver cannot resolve.
///
/// Invoked by `make xcode-trace-smoke`.
@MainActor
func runTraceSmokeTest() async -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nativ-trace-smoke-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var failures: [String] = []
    func check(_ condition: Bool, _ label: String) {
        print("  \(condition ? "ok  " : "FAIL") \(label)")
        if !condition { failures.append(label) }
    }

    let sessionID = UUID()
    let turn = ChatTraceTurn(sessionID: sessionID, turnID: UUID())
    let call = ChatTraceCall(turn: turn, requestID: UUID(), round: 0, modelID: "smoke-model")
    let userMessageID = UUID()
    let prompt = "what is the capital of france"

    var blocks: [TraceDisplayBlock] = []
    var exposures: [ResolvedExposure] = []
    var thrown: Error?

    do {
        let store = try TraceStore(url: directory.appendingPathComponent("Traces.sqlite3"))
        let producer = ChatTraceProducer(recorder: TraceRecorder(store: store))

        producer.sessionStarted(sessionID: sessionID, title: "Smoke", modelID: "smoke-model")
        producer.turnStarted(turn, messageID: userMessageID, text: prompt, modelID: "smoke-model")
        producer.requestComposed(
            RequestComposedPayload(
                systemSections: [
                    PromptSection(origin: .userSystemPrompt, label: "System prompt", body: "Be terse."),
                    PromptSection(origin: .toolGuide, label: "Using Nativ Tools", body: "Use tools."),
                ],
                tools: [ToolDescriptor(name: "web_search", origin: .builtIn)],
                parameters: SamplingParameters(temperature: 0.7, maxTokens: 512),
                messages: [
                    TraceMessageRef(
                        role: .user,
                        messageID: userMessageID.uuidString,
                        contentHash: TraceHash.content(prompt),
                        byteCount: prompt.utf8.count
                    )
                ]
            ),
            in: call
        )
        producer.delta(content: "Par", reasoning: "recalling", in: call)
        producer.responseCompleted(
            messageID: UUID(),
            content: "Paris",
            reasoning: "recalling",
            usage: TraceUsage(promptTokens: 12, completionTokens: 2),
            finishReason: "stop",
            in: call
        )
        producer.toolCall(callID: "c1", name: "web_search", argumentsJSON: #"{"q":"paris"}"#, in: call)
        producer.toolResult(callID: "c1", name: "web_search", output: "Paris", isError: false, in: call)
        producer.turnEnded(turn, status: "completed", roundCount: 1)
        await producer.drain()

        let events = try await store.events(forSession: sessionID.uuidString)
        let items = TraceReducer.items(for: events)
        blocks = TraceGrouping.blocks(for: items)

        let index = TraceExposureIndex(items: items)
        exposures = items.compactMap { item in
            guard case .exposure(let payload) = item.body else { return nil }
            return index.resolve(payload)
        }

        check(events.count == 7, "every emitted event reached the store (\(events.count))")
        check(events.map(\.seq) == Array(0..<Int64(events.count)), "sequence numbers are contiguous")
        check(
            events.map(\.kind) == [
                .sessionStarted, .turnStarted, .requestComposed,
                .responseCompleted, .toolCall, .toolResult, .turnEnded,
            ],
            "events landed in the order they were produced"
        )
    } catch {
        thrown = error
    }

    if let thrown {
        print("  FAIL threw: \(thrown)")
        return false
    }

    let turns = blocks.compactMap { block -> TraceTurn? in
        guard case .turn(let turn) = block else { return nil }
        return turn
    }
    check(turns.count == 1, "the transcript folded into one turn")
    check(turns.first?.calls.count == 1, "the turn holds one model call")

    let exposure = exposures.first
    check(exposure?.systemSections.count == 2, "both system sections survived the round trip")
    check(
        exposure?.systemSections.map(\.origin) == [.userSystemPrompt, .toolGuide],
        "section provenance survived the round trip"
    )
    check(exposure?.tools.first?.name == "web_search", "the advertised tool survived")
    check(exposure?.messages.first?.text == prompt, "the message reference resolved to its body")
    check(exposure?.messages.first?.isVerified == true, "the resolved body matches what was sent")

    let toolRows = turns.first?.segments.compactMap { segment -> TraceToolBody? in
        guard case .item(let item) = segment, case .tool(let tool) = item.body else { return nil }
        return tool
    } ?? []
    check(toolRows.count == 1, "the call and its result collapsed into one row")
    check(toolRows.first?.status == .completed, "the tool row is marked completed")
    check(toolRows.first?.output == "Paris", "the tool output survived")

    print(failures.isEmpty ? "\ntrace smoke test PASSED" : "\ntrace smoke test FAILED")
    return failures.isEmpty
}
