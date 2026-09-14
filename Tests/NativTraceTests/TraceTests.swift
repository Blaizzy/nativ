import NativTrace
import XCTest

final class TraceTests: XCTestCase {
    private var directory: URL!
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private var sequence: Int64 = 0

    override func setUpWithError() throws {
        sequence = 0
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testQueuePreservesProducerOrder() async throws {
        let store = try makeStore()
        let queue = TraceEventQueue(recorder: TraceRecorder(store: store))
        let scope = TraceScope(sessionID: "s", turnID: "u", requestID: "r")
        for index in 0..<100 {
            queue.record(ToolCallPayload(callID: "c\(index)", name: "read_file"), traceID: "t", scope: scope)
            queue.record(ToolResultPayload(callID: "c\(index)", output: "ok"), traceID: "t", scope: scope)
        }
        await queue.drain()

        let events = try await store.events(forTrace: "t")
        XCTAssertEqual(events.map(\.kind), (0..<100).flatMap { _ in [.toolCall, .toolResult] })
    }

    func testAbandonedOutputFlushesBeforeFailure() async throws {
        let store = try makeStore()
        let recorder = TraceRecorder(store: store)
        let scope = TraceScope(sessionID: "s", turnID: "u", requestID: "r")
        await recorder.appendDelta(content: "Pa", traceID: "t", scope: scope)
        await recorder.appendDelta(content: "ris", reasoning: "thinking", traceID: "t", scope: scope)
        await recorder.record(ResponseFailedPayload(message: "cancelled", isCancellation: true), traceID: "t", scope: scope)

        let events = try await store.events(forTrace: "t")
        XCTAssertEqual(events.map(\.kind), [.responseDelta, .responseFailed])
        XCTAssertEqual(ResponseDeltaPayload(event: events[0])?.content, "Paris")
        XCTAssertEqual(ResponseDeltaPayload(event: events[0])?.reasoning, "thinking")
    }

    func testStoreReopensAndPreservesLargeExposure() async throws {
        let url = directory.appendingPathComponent("Traces.sqlite3")
        let body = String(repeating: "prompt ", count: 3_000)
        let first = try TraceStore(url: url)
        try await first.record(
            kind: .requestComposed,
            payload: try RequestComposedPayload(
                systemSections: [PromptSection(origin: .toolGuide, label: "Guide", body: body)]
            ).makePayload(),
            traceID: "t",
            scope: TraceScope(sessionID: "s")
        )

        let reopened = try TraceStore(url: url)
        let next = try await reopened.record(
            kind: .turnStarted, payload: .object([:]), traceID: "t", scope: TraceScope(sessionID: "s")
        )
        let events = try await reopened.events(forTrace: "t")
        XCTAssertEqual(next.seq, 1)
        XCTAssertEqual(RequestComposedPayload(event: events[0])?.systemSections.first?.body, body)
        XCTAssertEqual(events[0].formatVersion, TraceEvent.currentFormatVersion)
    }

    func testRetentionKeepsNewestTraces() async throws {
        let store = try makeStore()
        for index in 0..<4 {
            try await store.record(
                kind: .turnStarted,
                payload: .object([:]),
                traceID: "t\(index)",
                scope: TraceScope(sessionID: "s"),
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
        let removed = try await store.prune(
            retaining: TraceRetentionWindow(days: nil, maximumTraces: 2), now: base
        )
        var remaining: [Int] = []
        for index in 0..<4 where !(try await store.events(forTrace: "t\(index)")).isEmpty {
            remaining.append(index)
        }
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(remaining, [2, 3])
    }

    func testReducerFoldsStreamingCompletionAndToolResult() throws {
        let events = [
            event(.responseDelta, try ResponseDeltaPayload(content: "Par").makePayload(), requestID: "r"),
            event(.toolCall, try ToolCallPayload(callID: "c", name: "search").makePayload(), requestID: "r"),
            event(.toolResult, try ToolResultPayload(callID: "c", output: "ok").makePayload(), requestID: "r"),
            event(.responseCompleted, try ResponseCompletedPayload(messageID: "a", content: "Paris").makePayload(), requestID: "r"),
        ]
        let items = TraceReducer.items(for: events)
        XCTAssertEqual(items.count, 2)
        guard case .message(let message) = items[0].body, case .tool(let tool) = items[1].body else {
            return XCTFail("expected message then tool")
        }
        XCTAssertEqual(message.text, "Paris")
        XCTAssertFalse(message.isStreaming)
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(tool.output, "ok")
    }

    func testReducerKeepsUnknownAndUnreadableEventsVisible() throws {
        let items = TraceReducer.items(for: [
            event(TraceEventKind(rawValue: "future"), .object(["value": .int(1)])),
            event(.toolCall, .object(["wrong": .bool(true)])),
        ])
        XCTAssertEqual(items.count, 2)
        guard case .unknown(let kind, _) = items[0].body, case .unknown = items[1].body else {
            return XCTFail("unknown data must remain inspectable")
        }
        XCTAssertEqual(kind.rawValue, "future")
    }

    func testGroupingPreservesEveryItemAndEachCall() throws {
        let events = [
            event(.turnStarted, try TurnStartedPayload(messageID: "u", text: "hi").makePayload()),
            event(.requestComposed, try RequestComposedPayload().makePayload(), requestID: "r1"),
            event(.toolCall, try ToolCallPayload(callID: "c", name: "search").makePayload(), requestID: "r1"),
            event(.requestComposed, try RequestComposedPayload().makePayload(), requestID: "r2"),
        ]
        let items = TraceReducer.items(for: events)
        let blocks = TraceGrouping.blocks(for: items)
        let ids = blocks.flatMap { block -> [String] in
            switch block {
            case .boundary(let item): [item.id]
            case .turn(let turn): (turn.prompt.map { [$0.id] } ?? []) + turn.segments.map(\.id)
            }
        }
        XCTAssertEqual(Set(ids), Set(items.map(\.id)))
        XCTAssertEqual(ids.count, items.count)
        XCTAssertEqual(ids.compactMap { id in items.first { $0.id == id } }.filter {
            if case .exposure = $0.body { true } else { false }
        }.count, 2)
    }

    func testJSONIsCanonicalAndForwardCompatible() throws {
        let value: TraceJSON = .object(["b": .int(2), "a": .array([.bool(true), .double(2.5)])])
        let encoded = try value.canonicalString()
        XCTAssertEqual(encoded, #"{"a":[true,2.5],"b":2}"#)
        XCTAssertEqual(try TraceJSON.decode(encoded).canonicalString(), encoded)
        XCTAssertEqual(try JSONDecoder().decode(TraceEventKind.self, from: Data(#""future""#.utf8)).rawValue, "future")
    }

    private func makeStore() throws -> TraceStore {
        try TraceStore(url: directory.appendingPathComponent("Traces.sqlite3"))
    }

    private func event(_ kind: TraceEventKind, _ payload: TraceJSON, requestID: String? = nil) -> TraceEvent {
        defer { sequence += 1 }
        return TraceEvent(
            traceID: "t", seq: sequence, timestamp: base.addingTimeInterval(Double(sequence)),
            kind: kind, scope: TraceScope(sessionID: "s", turnID: "u", requestID: requestID), payload: payload
        )
    }
}
