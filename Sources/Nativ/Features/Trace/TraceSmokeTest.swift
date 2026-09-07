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
        fflush(stdout)
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
                        contentHash: TraceHash.content(prompt)
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

        // A second model takes over the same chat. It must get its own trace,
        // and that trace must still account for what it was shown.
        let secondCall = ChatTraceCall(
            turn: ChatTraceTurn(sessionID: sessionID, turnID: UUID()),
            requestID: UUID(),
            round: 0,
            modelID: "smoke-model-2"
        )
        let followUpID = UUID()
        let followUp = "and germany?"
        producer.turnStarted(
            secondCall.turn, messageID: followUpID, text: followUp, modelID: "smoke-model-2"
        )
        producer.requestComposed(
            RequestComposedPayload(
                systemSections: [
                    PromptSection(origin: .userSystemPrompt, label: "System prompt", body: "Be terse.")
                ],
                messages: [
                    TraceMessageRef(
                        role: .user,
                        messageID: userMessageID.uuidString,
                        contentHash: TraceHash.content(prompt)
                    ),
                    TraceMessageRef(
                        role: .user,
                        messageID: followUpID.uuidString,
                        contentHash: TraceHash.content(followUp)
                    ),
                ],
                advertisesTools: false
            ),
            in: secondCall
        )
        producer.responseCompleted(
            messageID: UUID(), content: "Berlin.", reasoning: nil,
            usage: nil, finishReason: "stop", in: secondCall
        )
        producer.turnEnded(secondCall.turn, status: "completed", roundCount: 1)
        await producer.drain()

        let allTraces = try await store.traces(forSession: sessionID.uuidString)
        check(allTraces.count == 2, "each model got its own trace (\(allTraces.count))")
        check(
            allTraces.compactMap(\.modelIDs.first) == ["smoke-model", "smoke-model-2"],
            "traces are ordered by when each model took over"
        )

        if allTraces.count != 2 {
            print("  (found traces: \(allTraces.map { "\($0.traceID) \($0.modelIDs)" }))")
        }
        let firstKinds = try await store.events(forTrace: allTraces.first?.traceID ?? "").map(\.kind)
        check(
            firstKinds == [
                .sessionStarted, .turnStarted, .requestComposed,
                .responseCompleted, .toolCall, .toolResult, .turnEnded,
            ],
            "the first model's trace holds its events in order (\(firstKinds.map(\.rawValue)))"
        )

        let secondKinds = try await store.events(forTrace: allTraces.dropFirst().first?.traceID ?? "").map(\.kind)
        check(
            secondKinds == [
                .modelSwitched, .turnStarted, .requestComposed, .responseCompleted, .turnEnded,
            ],
            "the second model's trace opens by naming the handover (\(secondKinds.map(\.rawValue)))"
        )

        // Drive the view model the panel actually uses, rather than
        // re-implementing the fold here and testing a copy.
        let inspector = TraceInspectorViewModel(store: store)
        await inspector.loadSession(sessionID)
        check(inspector.loadFailure == nil, "the inspector loaded without error")
        check(inspector.instances.count == 2, "the chat exposes both model instances")

        let second = inspector.instances.last
        check(second?.precedingModelID == "smoke-model", "the later trace names who it took over from")
        check(
            second?.inheritedContext.count == 1,
            "the later trace accounts for the message it inherited (\(second?.inheritedContext.count ?? -1))"
        )
        check(
            second?.inheritedContext.first?.text == prompt,
            "the inherited message resolves to its body from the previous model's trace"
        )
        check(
            second?.inheritedContext.first?.isVerified == true,
            "the inherited body matches what the later model was actually shown"
        )

        inspector.selectedInstanceID = inspector.instances.first?.id
        blocks = inspector.blocks
        exposures = inspector.calls.compactMap { inspector.exposure(for: $0.id) }
        check(inspector.calls.count == 1, "the first instance lists its own single call")
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
    let turnCalls = turns.first?.segments.filter {
        if case .exposure = $0.body { true } else { false }
    } ?? []
    check(turnCalls.count == 1, "the turn holds one model call")

    let exposure = exposures.first
    check(exposure?.systemSections.count == 2, "both system sections survived the round trip")
    check(
        exposure?.systemSections.map(\.origin) == [.userSystemPrompt, .toolGuide],
        "section provenance survived the round trip"
    )
    check(exposure?.tools.first?.name == "web_search", "the advertised tool survived")
    check(exposure?.messages.first?.text == prompt, "the message reference resolved to its body")
    check(exposure?.messages.first?.isVerified == true, "the resolved body matches what was sent")

    let toolRows = turns.first?.segments.compactMap { item -> TraceToolBody? in
        guard case .tool(let tool) = item.body else { return nil }
        return tool
    } ?? []
    check(toolRows.count == 1, "the call and its result collapsed into one row")
    check(toolRows.first?.status == .completed, "the tool row is marked completed")
    check(toolRows.first?.output == "Paris", "the tool output survived")

    print(failures.isEmpty ? "\ntrace smoke test PASSED" : "\ntrace smoke test FAILED")
    return failures.isEmpty
}
