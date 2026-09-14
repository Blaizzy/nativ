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
            queue.record(ToolCallPayload(callID: "c\(index)", name: "read_file"), traceID: "t1", scope: scope)
        }
        await queue.drain()

        let recorded = try await store.events(forTrace: "t1").compactMap { ToolCallPayload(event: $0)?.callID }

        XCTAssertEqual(recorded, (0..<200).map { "c\($0)" }, "the queue may never reorder what a producer emitted")
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

}
