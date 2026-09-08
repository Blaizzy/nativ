import XCTest
import NativTrace

final class TraceRecorderTests: XCTestCase {
    private var directory: URL!
    private let scope = TraceScope(sessionID: "s1", turnID: "u1", requestID: "r1")

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

    func testCompletedCallDoesNotPersistIndividualDeltas() async throws {
        let store = try makeStore()
        let recorder = TraceRecorder(store: store)

        for token in ["Pa", "ri", "s"] {
            await recorder.appendDelta(content: token, traceID: "t1", scope: scope)
        }
        await recorder.discardPartial(traceID: "t1", scope: scope)
        await recorder.record(
            ResponseCompletedPayload(messageID: "a1", content: "Paris"),
            traceID: "t1", scope: scope
        )

        let events = try await store.events(forTrace: "t1")

        XCTAssertEqual(events.map(\.kind), [.responseCompleted], "one row per completed call")
    }

    func testAbandonedStreamIsPersistedSoPartialOutputSurvives() async throws {
        let store = try makeStore()
        let recorder = TraceRecorder(store: store)

        await recorder.appendDelta(content: "Pa", traceID: "t1", scope: scope)
        await recorder.appendDelta(content: "ri", reasoning: "hmm", traceID: "t1", scope: scope)
        await recorder.record(
            ResponseFailedPayload(message: "cancelled", isCancellation: true),
            traceID: "t1", scope: scope
        )

        let events = try await store.events(forTrace: "t1")

        XCTAssertEqual(events.map(\.kind), [.responseDelta, .responseFailed],
                       "the partial flushes before the failure that ended it")
        let partial = try XCTUnwrap(ResponseDeltaPayload(event: events[0]))
        XCTAssertEqual(partial.content, "Pari")
        XCTAssertEqual(partial.reasoning, "hmm")
    }

    func testDeltasFromDifferentCallsAreKeptApart() async throws {
        let store = try makeStore()
        let recorder = TraceRecorder(store: store)
        let other = TraceScope(sessionID: "s1", turnID: "u1", requestID: "r2")

        await recorder.appendDelta(content: "one", traceID: "t1", scope: scope)
        await recorder.appendDelta(content: "two", traceID: "t1", scope: other)
        await recorder.flushAll()

        let events = try await store.events(forTrace: "t1")
        let bodies = events.compactMap { ResponseDeltaPayload(event: $0)?.content }

        XCTAssertEqual(Set(bodies), ["one", "two"])
    }

    func testPartialResponseIsReadableBeforeItIsSealed() async throws {
        let recorder = TraceRecorder(store: try makeStore())

        await recorder.appendDelta(content: "Pa", traceID: "t1", scope: scope)
        await recorder.appendDelta(content: "ris", traceID: "t1", scope: scope)

        let partial = await recorder.partialResponse(traceID: "t1", scope: scope)

        XCTAssertEqual(partial?.content, "Paris")
    }

    func testSequenceNumbersAreContiguousAcrossRecordings() async throws {
        let store = try makeStore()
        let recorder = TraceRecorder(store: store)

        await recorder.record(SessionStartedPayload(title: "s"), traceID: "t1", scope: scope)
        await recorder.record(TurnStartedPayload(messageID: "m1", text: "hi"), traceID: "t1", scope: scope)
        await recorder.record(ToolCallPayload(callID: "c1", name: "web_search"), traceID: "t1", scope: scope)

        let events = try await store.events(forTrace: "t1")

        XCTAssertEqual(events.map(\.seq), [0, 1, 2])
    }

    func testRetentionWindowComputesItsCutoff() {
        let reference = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)

        XCTAssertEqual(
            TraceRetentionWindow(days: 7, maximumTraces: nil).cutoff(from: reference),
            Date(timeIntervalSince1970: 3 * 24 * 60 * 60)
        )
        XCTAssertEqual(
            TraceRetentionWindow(days: nil, maximumTraces: 10).cutoff(from: reference),
            .distantPast
        )
    }
}
