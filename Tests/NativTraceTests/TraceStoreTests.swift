import XCTest
import NativTrace

final class TraceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> TraceStore {
        try TraceStore(url: directory.appendingPathComponent("Traces.sqlite3"))
    }

    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testSequenceReservationsDoNotOverlap() async throws {
        let store = try makeStore()

        let first = try await store.reserveSequence(forTrace: "t1", count: 3)
        let second = try await store.reserveSequence(forTrace: "t1")

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 3)
    }

    func testSequenceResumesFromStoredEventsAfterReopen() async throws {
        let url = directory.appendingPathComponent("Traces.sqlite3")
        let first = try TraceStore(url: url)
        try await first.append(
            TraceEvent(traceID: "t1", seq: 7, timestamp: base, kind: .turnStarted)
        )

        let reopened = try TraceStore(url: url)

        let next = try await reopened.reserveSequence(forTrace: "t1")
        XCTAssertEqual(next, 8)
    }

    func testEventsReadBackInSequenceOrder() async throws {
        let store = try makeStore()
        try await store.append([
            makeEvent(seq: 2, kind: .responseCompleted),
            makeEvent(seq: 0, kind: .sessionStarted),
            makeEvent(seq: 1, kind: .turnStarted),
        ])

        let events = try await store.events(forTrace: "t1")

        XCTAssertEqual(events.map(\.seq), [0, 1, 2])
    }

    func testComposedExposureSurvivesStorage() async throws {
        let store = try makeStore()
        let composed = RequestComposedPayload(
            systemSections: [
                PromptSection(origin: .userSystemPrompt, label: "System prompt", body: "Be terse."),
                PromptSection(origin: .skill, label: "Chicago footnotes", body: "Cite sources."),
            ],
            tools: [
                ToolDescriptor(name: "web_search", origin: .builtIn, parameters: ["type": "object"]),
                ToolDescriptor(name: "list_issues", origin: .mcp, originDetail: "github"),
            ],
            parameters: SamplingParameters(temperature: 0.7, maxTokens: 2048, thinkingEnabled: true),
            advertisesTools: true
        )
        try await store.append(
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .requestComposed,
                scope: TraceScope(sessionID: "s1", turnID: "u1", requestID: "r1", roundIndex: 0),
                payload: try composed.makePayload()
            )
        )

        let events = try await store.events(forRequest: "r1")
        let restored = try XCTUnwrap(RequestComposedPayload(event: try XCTUnwrap(events.first)))

        XCTAssertEqual(restored.systemSections.map(\.origin), [.userSystemPrompt, .skill])
        XCTAssertEqual(restored.systemSections[1].label, "Chicago footnotes")
        XCTAssertEqual(restored.tools.first { $0.name == "list_issues" }?.originDetail, "github")
        XCTAssertEqual(restored.parameters.temperature, 0.7)
        XCTAssertTrue(restored.advertisesTools)
    }

    func testLargePayloadSurvivesCompressionRoundTrip() async throws {
        let store = try makeStore()
        let body = String(repeating: "The quick brown fox. ", count: 3_000)
        try await store.append(
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .requestComposed,
                payload: try RequestComposedPayload(
                    systemSections: [PromptSection(origin: .toolGuide, label: "Tool guide", body: body)]
                ).makePayload()
            )
        )

        let events = try await store.events(forTrace: "t1")
        let restored = try XCTUnwrap(RequestComposedPayload(event: try XCTUnwrap(events.first)))

        XCTAssertEqual(restored.systemSections.first?.body, body)
    }

    func testIndexTracksEventCountsAndModels() async throws {
        let store = try makeStore()
        try await store.append([
            makeEvent(seq: 0, kind: .sessionStarted, modelID: "qwen"),
            makeEvent(seq: 1, kind: .modelSwitched, modelID: "gemma"),
        ])

        let traces = try await store.recentTraces()
        let summary = try XCTUnwrap(traces.first)

        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.lastSeq, 1)
        XCTAssertEqual(summary.modelIDs, ["gemma", "qwen"])
    }

    func testRebuildIndexReproducesTheDerivedRows() async throws {
        let store = try makeStore()
        try await store.append([
            makeEvent(seq: 0, kind: .sessionStarted, modelID: "qwen"),
            makeEvent(seq: 1, kind: .turnStarted, modelID: "qwen"),
        ])
        let before = try await store.recentTraces()

        try await store.rebuildIndex()
        let after = try await store.recentTraces()

        XCTAssertEqual(before.map(\.traceID), after.map(\.traceID))
        XCTAssertEqual(before.map(\.eventCount), after.map(\.eventCount))
        XCTAssertEqual(before.map(\.modelIDs), after.map(\.modelIDs))
    }

    func testPruneDropsTracesOlderThanTheCutoff() async throws {
        let store = try makeStore()
        try await store.append(makeEvent(seq: 0, kind: .turnStarted))

        let removed = try await store.prune(before: base.addingTimeInterval(10), maxTraces: nil)

        let remaining = try await store.events(forTrace: "t1")
        let traces = try await store.recentTraces()
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(traces.isEmpty)
    }

    func testPruneKeepsTheNewestTracesWhenOverTheLimit() async throws {
        let store = try makeStore()
        for index in 0..<5 {
            try await store.append(
                TraceEvent(
                    traceID: "keep\(index)", seq: 0,
                    timestamp: base.addingTimeInterval(Double(index)),
                    kind: .turnStarted
                )
            )
        }

        let removed = try await store.prune(before: Date(timeIntervalSince1970: 0), maxTraces: 2)

        let kept = try await store.recentTraces().map(\.traceID).sorted()
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(kept, ["keep3", "keep4"])
    }

    private func makeEvent(
        seq: Int64,
        kind: TraceEventKind,
        modelID: String? = nil
    ) -> TraceEvent {
        TraceEvent(
            traceID: "t1",
            seq: seq,
            timestamp: base.addingTimeInterval(Double(seq)),
            kind: kind,
            scope: TraceScope(sessionID: "s1", modelID: modelID)
        )
    }
}
