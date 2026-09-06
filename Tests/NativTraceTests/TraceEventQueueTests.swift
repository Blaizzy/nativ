import XCTest
import NativTrace

final class TraceEventQueueTests: XCTestCase {
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

    func testEventsReachTheStoreInTheOrderTheyWereQueued() async throws {
        let store = try makeStore()
        let queue = TraceEventQueue(recorder: TraceRecorder(store: store))
        let scope = TraceScope(sessionID: "s1", turnID: "u1", requestID: "r1")

        for index in 0..<200 {
            queue.record(
                kind: .toolCall,
                payload: ["index": .int(Int64(index))],
                traceID: "t1",
                scope: scope
            )
        }
        await queue.drain()

        let recorded = try await store.events(forTrace: "t1").compactMap { $0.payload["index"]?.intValue }

        XCTAssertEqual(recorded, Array(0..<200), "the queue may never reorder what a producer emitted")
    }

    func testAToolResultNeverOvertakesTheCallItAnswers() async throws {
        let store = try makeStore()
        let queue = TraceEventQueue(recorder: TraceRecorder(store: store))
        let scope = TraceScope(sessionID: "s1", turnID: "u1", requestID: "r1")

        for index in 0..<50 {
            queue.record(
                ToolCallPayload(callID: "c\(index)", name: "read_file"),
                traceID: "t1", scope: scope
            )
            queue.record(
                ToolResultPayload(callID: "c\(index)", output: "ok"),
                traceID: "t1", scope: scope
            )
        }
        await queue.drain()

        let kinds = try await store.events(forTrace: "t1").map(\.kind)
        let expected = (0..<50).flatMap { _ in [TraceEventKind.toolCall, .toolResult] }

        XCTAssertEqual(kinds, expected)
    }

    func testStreamedDeltasAreFlushedBeforeTheEventThatEndsThem() async throws {
        let store = try makeStore()
        let queue = TraceEventQueue(recorder: TraceRecorder(store: store))
        let scope = TraceScope(sessionID: "s1", turnID: "u1", requestID: "r1")

        queue.delta(content: "Pa", reasoning: nil, traceID: "t1", scope: scope)
        queue.delta(content: "ris", reasoning: nil, traceID: "t1", scope: scope)
        queue.record(
            ResponseFailedPayload(message: "cancelled", isCancellation: true),
            traceID: "t1", scope: scope
        )
        await queue.drain()

        let events = try await store.events(forTrace: "t1")

        XCTAssertEqual(events.map(\.kind), [.responseDelta, .responseFailed])
        XCTAssertEqual(ResponseDeltaPayload(event: events[0])?.content, "Paris")
    }

    func testDrainReturnsOnceQueuedWorkHasLanded() async throws {
        let store = try makeStore()
        let queue = TraceEventQueue(recorder: TraceRecorder(store: store))

        queue.record(kind: .turnStarted, payload: .object([:]), traceID: "t1", scope: TraceScope())
        await queue.drain()

        let events = try await store.events(forTrace: "t1")
        XCTAssertEqual(events.count, 1)
    }
}
