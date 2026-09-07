import XCTest
import NativTrace

final class TraceGroupingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private var seq: Int64 = 0

    override func setUp() {
        super.setUp()
        seq = 0
    }

    func testEveryItemLandsInExactlyOneBlock() throws {
        let items = TraceReducer.items(for: try sampleEvents())
        let blocks = TraceGrouping.blocks(for: items)

        XCTAssertEqual(
            Set(itemIDs(in: blocks)),
            Set(items.map(\.id)),
            "grouping is presentation only and may never lose or duplicate a row"
        )
        XCTAssertEqual(itemIDs(in: blocks).count, items.count)
    }

    func testUserPromptOpensATurn() throws {
        let items = TraceReducer.items(for: try sampleEvents())
        let blocks = TraceGrouping.blocks(for: items)

        let turns = blocks.compactMap { block -> TraceTurn? in
            guard case .turn(let turn) = block else { return nil }
            return turn
        }

        XCTAssertEqual(turns.count, 1)
        guard case .message(let prompt) = try XCTUnwrap(turns.first?.prompt).body else {
            return XCTFail("expected the prompt to be the user message")
        }
        XCTAssertEqual(prompt.text, "hi")
    }

    func testModelSwitchDrawsABoundaryBetweenTurns() throws {
        let events = [
            event(.turnStarted, try TurnStartedPayload(messageID: "m1", text: "one").makePayload(), turnID: "u1"),
            event(.modelSwitched, try ModelSwitchedPayload(from: "qwen", to: "gemma").makePayload(), turnID: nil),
            event(.turnStarted, try TurnStartedPayload(messageID: "m2", text: "two").makePayload(), turnID: "u2"),
        ]

        let blocks = TraceGrouping.blocks(for: TraceReducer.items(for: events))

        guard blocks.count == 3, case .boundary(let boundary) = blocks[1] else {
            return XCTFail("expected turn, boundary, turn — got \(blocks.count) blocks")
        }
        XCTAssertEqual(boundary.kind, .modelSwitched)
        XCTAssertEqual(boundary.title, "Switched to gemma")
        XCTAssertEqual(boundary.detail, "from qwen")
    }

    func testEveryToolRowSurvivesGrouping() throws {
        var events = [event(.turnStarted, try TurnStartedPayload(messageID: "m1", text: "go").makePayload())]
        for index in 0..<4 {
            events.append(event(.toolCall, try ToolCallPayload(callID: "c\(index)", name: "read_file").makePayload()))
        }

        let blocks = TraceGrouping.blocks(for: TraceReducer.items(for: events))
        guard case .turn(let turn) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a turn")
        }

        XCTAssertEqual(turn.segments.count, 4, "an inspector shows every call, it does not hide them")
    }

    func testCallsExposesOneEntryPerModelCall() throws {
        let events = [
            event(.turnStarted, try TurnStartedPayload(messageID: "m1", text: "go").makePayload()),
            event(.requestComposed, try RequestComposedPayload().makePayload(), requestID: "r1"),
            event(.toolCall, try ToolCallPayload(callID: "c1", name: "web_search").makePayload(), requestID: "r1"),
            event(.requestComposed, try RequestComposedPayload().makePayload(), requestID: "r2"),
        ]

        let blocks = TraceGrouping.blocks(for: TraceReducer.items(for: events))
        guard case .turn(let turn) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected a turn")
        }

        let calls = turn.segments.filter { if case .exposure = $0.body { true } else { false } }
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - Helpers

    private func sampleEvents() throws -> [TraceEvent] {
        [
            event(.sessionStarted, try SessionStartedPayload(title: "Session").makePayload(), turnID: nil),
            event(.turnStarted, try TurnStartedPayload(messageID: "m1", text: "hi").makePayload()),
            event(.requestComposed, try RequestComposedPayload().makePayload(), requestID: "r1"),
            event(.toolCall, try ToolCallPayload(callID: "c1", name: "web_search").makePayload(), requestID: "r1"),
            event(.toolResult, try ToolResultPayload(callID: "c1", output: "ok").makePayload(), requestID: "r1"),
            event(.responseCompleted, try ResponseCompletedPayload(messageID: "a1", content: "Paris").makePayload(), requestID: "r1"),
            event(.turnEnded, try TurnEndedPayload(status: "completed").makePayload()),
        ]
    }

    private func itemIDs(in blocks: [TraceDisplayBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .boundary(let boundary): [boundary.id]
            case .loose(let item): [item.id]
            case .turn(let turn):
                (turn.prompt.map { [$0.id] } ?? []) + turn.segments.map(\.id)
            }
        }
    }

    private func event(
        _ kind: TraceEventKind,
        _ payload: TraceJSON,
        turnID: String? = "u1",
        requestID: String? = nil
    ) -> TraceEvent {
        defer { seq += 1 }
        return TraceEvent(
            traceID: "t1", seq: seq, timestamp: base.addingTimeInterval(Double(seq)),
            kind: kind,
            scope: TraceScope(sessionID: "s1", turnID: turnID, requestID: requestID),
            payload: payload
        )
    }
}
