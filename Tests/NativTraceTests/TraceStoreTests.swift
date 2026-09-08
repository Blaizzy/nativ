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

    func testRecordAllocatesContiguousSequences() async throws {
        let store = try makeStore()

        for _ in 0..<3 {
            try await store.record(
                kind: .turnStarted, payload: .object([:]), traceID: "t1", scope: TraceScope()
            )
        }

        let events = try await store.events(forTrace: "t1")
        XCTAssertEqual(events.map(\.seq), [0, 1, 2])
    }

    func testSequenceResumesFromStoredEventsAfterReopen() async throws {
        let url = directory.appendingPathComponent("Traces.sqlite3")
        let first = try TraceStore(url: url)
        try await first.insert(preSequenced: [
            TraceEvent(traceID: "t1", seq: 7, timestamp: base, kind: .turnStarted)
        ])

        let reopened = try TraceStore(url: url)
        let recorded = try await reopened.record(
            kind: .turnStarted, payload: .object([:]), traceID: "t1", scope: TraceScope()
        )

        XCTAssertEqual(recorded.seq, 8, "a reopened store resumes after what is already stored")
    }

    func testReadablePayloadCarriesNoFailureMarker() async throws {
        let store = try makeStore()
        try await store.insert(preSequenced: [
            TraceEvent(traceID: "t1", seq: 0, timestamp: base, kind: .turnStarted)
        ])

        let events = try await store.events(forTrace: "t1")

        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].payload[TraceStore.unreadablePayloadKey])
    }

    func testPayloadWrittenByAFutureCodecIsRejectedRatherThanGuessed() throws {
        let encoded = try TracePayloadCodec.encode(["a": 1])

        XCTAssertThrowsError(
            try TracePayloadCodec.decode(
                data: encoded.data,
                encoding: "json+somethingnew",
                byteCount: encoded.byteCount
            )
        ) { error in
            guard case TraceStoreError.unsupportedPayloadEncoding(let name) = error else {
                return XCTFail("expected an unsupported-encoding error, got \(error)")
            }
            XCTAssertEqual(name, "json+somethingnew")
        }
    }

    func testCorruptCompressedPayloadIsReportedRatherThanCrashing() throws {
        XCTAssertThrowsError(
            try TracePayloadCodec.decode(
                data: Data([0x00, 0x01, 0x02, 0x03]),
                encoding: "json+deflate",
                byteCount: 64
            )
        )
    }

    func testEventsCanBePaged() async throws {
        let store = try makeStore()
        for _ in 0..<5 {
            try await store.record(
                kind: .turnStarted, payload: .object([:]), traceID: "t1", scope: TraceScope()
            )
        }

        let firstPage = try await store.events(forTrace: "t1", limit: 2)
        let secondPage = try await store.events(forTrace: "t1", after: firstPage.last?.seq, limit: 2)

        XCTAssertEqual(firstPage.map(\.seq), [0, 1])
        XCTAssertEqual(secondPage.map(\.seq), [2, 3])
    }

    func testEventsReadBackInSequenceOrder() async throws {
        let store = try makeStore()
        try await store.insert(preSequenced: [
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
        try await store.insert(preSequenced: [
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .requestComposed,
                scope: TraceScope(sessionID: "s1", turnID: "u1", requestID: "r1", roundIndex: 0),
                payload: try composed.makePayload()
            )
        ])

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
        try await store.insert(preSequenced: [
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .requestComposed,
                payload: try RequestComposedPayload(
                    systemSections: [PromptSection(origin: .toolGuide, label: "Tool guide", body: body)]
                ).makePayload()
            )
        ])

        let events = try await store.events(forTrace: "t1")
        let restored = try XCTUnwrap(RequestComposedPayload(event: try XCTUnwrap(events.first)))

        XCTAssertEqual(restored.systemSections.first?.body, body)
    }

    func testIndexTracksEventCountsAndModels() async throws {
        let store = try makeStore()
        try await store.insert(preSequenced: [
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
        try await store.insert(preSequenced: [
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
        try await store.insert(preSequenced: [makeEvent(seq: 0, kind: .turnStarted)])

        let removed = try await store.prune(
            retaining: TraceRetentionWindow(days: 1, maximumTraces: nil),
            now: base.addingTimeInterval(2 * 24 * 60 * 60)
        )

        let remaining = try await store.events(forTrace: "t1")
        let traces = try await store.recentTraces()
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(traces.isEmpty)
    }

    func testBothRetentionLimitsApply() async throws {
        let store = try makeStore()
        for index in 0..<4 {
            try await store.insert(preSequenced: [
                TraceEvent(
                    traceID: "t\(index)", seq: 0,
                    timestamp: base.addingTimeInterval(Double(index) * 24 * 60 * 60),
                    kind: .turnStarted
                )
            ])
        }

        let removed = try await store.prune(
            retaining: TraceRetentionWindow(days: 2, maximumTraces: 2),
            now: base.addingTimeInterval(4 * 24 * 60 * 60)
        )

        let kept = try await store.recentTraces().map(\.traceID).sorted()
        XCTAssertEqual(removed, 2, "age removes t0 and t1; the count limit would keep two anyway")
        XCTAssertEqual(kept, ["t2", "t3"])
    }

    func testPruneKeepsTheNewestTracesWhenOverTheLimit() async throws {
        let store = try makeStore()
        for index in 0..<5 {
            try await store.insert(preSequenced: [
                TraceEvent(
                    traceID: "keep\(index)", seq: 0,
                    timestamp: base.addingTimeInterval(Double(index)),
                    kind: .turnStarted
                )
            ])
        }

        let removed = try await store.prune(
            retaining: TraceRetentionWindow(days: nil, maximumTraces: 2), now: base
        )

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
