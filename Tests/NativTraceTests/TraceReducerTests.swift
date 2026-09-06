import XCTest
import NativTrace

final class TraceReducerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)
    private var seq: Int64 = 0

    override func setUp() {
        super.setUp()
        seq = 0
    }

    func testUserPromptBecomesAMessage() throws {
        let items = TraceReducer.items(for: [
            event(.turnStarted, try TurnStartedPayload(messageID: "m1", text: "hi").makePayload())
        ])

        guard case .message(let message) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a message item")
        }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "hi")
    }

    func testStreamingDeltasAccumulateIntoOneMessage() throws {
        let items = TraceReducer.items(for: [
            event(.responseDelta, try ResponseDeltaPayload(content: "Par").makePayload(), requestID: "r1"),
            event(.responseDelta, try ResponseDeltaPayload(content: "is").makePayload(), requestID: "r1"),
            event(.responseDelta, try ResponseDeltaPayload(reasoning: "thinking").makePayload(), requestID: "r1"),
        ])

        XCTAssertEqual(items.count, 1, "deltas fold into the message they belong to")
        guard case .message(let message) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a message item")
        }
        XCTAssertEqual(message.text, "Paris")
        XCTAssertEqual(message.reasoning, "thinking")
        XCTAssertTrue(message.isStreaming)
    }

    func testCompletionSealsTheStreamingMessage() throws {
        let items = TraceReducer.items(for: [
            event(.responseDelta, try ResponseDeltaPayload(content: "Par").makePayload(), requestID: "r1"),
            event(
                .responseCompleted,
                try ResponseCompletedPayload(
                    messageID: "a1",
                    content: "Paris",
                    usage: TraceUsage(promptTokens: 12, completionTokens: 3),
                    finishReason: "stop"
                ).makePayload(),
                requestID: "r1"
            ),
        ])

        XCTAssertEqual(items.count, 1)
        guard case .message(let message) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a message item")
        }
        XCTAssertFalse(message.isStreaming)
        XCTAssertEqual(message.text, "Paris")
        XCTAssertEqual(message.usage?.promptTokens, 12)
        XCTAssertEqual(message.finishReason, "stop")
    }

    func testDeltasFromDifferentCallsDoNotMerge() throws {
        let items = TraceReducer.items(for: [
            event(.responseDelta, try ResponseDeltaPayload(content: "a").makePayload(), requestID: "r1"),
            event(.responseDelta, try ResponseDeltaPayload(content: "b").makePayload(), requestID: "r2"),
        ])

        XCTAssertEqual(items.count, 2)
    }

    func testToolCallAndResultCollapseIntoOneItem() throws {
        let items = TraceReducer.items(for: [
            event(.toolCall, try ToolCallPayload(
                callID: "c1", name: "web_search", origin: .builtIn, arguments: ["q": "paris"]
            ).makePayload()),
            event(.toolResult, try ToolResultPayload(
                callID: "c1", output: "2 results", durationMilliseconds: 340
            ).makePayload()),
        ])

        XCTAssertEqual(items.count, 1, "a call and its result are one row")
        guard case .tool(let tool) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a tool item")
        }
        XCTAssertEqual(tool.name, "web_search")
        XCTAssertEqual(tool.origin, .builtIn)
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(tool.output, "2 results")
        XCTAssertEqual(tool.durationMilliseconds, 340)
        XCTAssertEqual(tool.arguments?["q"]?.stringValue, "paris")
    }

    func testFailedToolResultMarksTheCallFailed() throws {
        let items = TraceReducer.items(for: [
            event(.toolCall, try ToolCallPayload(callID: "c1", name: "terminal").makePayload()),
            event(.toolResult, try ToolResultPayload(
                callID: "c1", output: "permission denied", isError: true
            ).makePayload()),
        ])

        guard case .tool(let tool) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a tool item")
        }
        XCTAssertEqual(tool.status, .failed)
    }

    func testDeniedConsentStopsTheCall() throws {
        let items = TraceReducer.items(for: [
            event(.toolConsent, try ToolConsentPayload(
                callID: "c1", name: "terminal", decision: "requested"
            ).makePayload()),
            event(.toolConsent, try ToolConsentPayload(
                callID: "c1", decision: "denied"
            ).makePayload()),
        ])

        XCTAssertEqual(items.count, 1)
        guard case .tool(let tool) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a tool item")
        }
        XCTAssertEqual(tool.status, .denied)
        XCTAssertEqual(tool.consentDecision, "denied")
    }

    func testApprovedConsentLetsTheCallRun() throws {
        let items = TraceReducer.items(for: [
            event(.toolConsent, try ToolConsentPayload(callID: "c1", name: "terminal", decision: "requested").makePayload()),
            event(.toolConsent, try ToolConsentPayload(callID: "c1", decision: "approved").makePayload()),
            event(.toolCall, try ToolCallPayload(callID: "c1", name: "terminal").makePayload()),
        ])

        guard case .tool(let tool) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected a tool item")
        }
        XCTAssertEqual(tool.status, .running)
    }

    func testUnknownEventKindStillProducesARow() throws {
        let items = TraceReducer.items(for: [
            event(TraceEventKind(rawValue: "invented_later"), ["detail": "something"])
        ])

        guard case .unknown(let kind, let payload) = try XCTUnwrap(items.first).body else {
            return XCTFail("expected an unknown item")
        }
        XCTAssertEqual(kind.rawValue, "invented_later")
        XCTAssertEqual(payload["detail"]?.stringValue, "something")
    }

    func testUnreadablePayloadOfAKnownKindIsSurfacedNotDropped() throws {
        let items = TraceReducer.items(for: [
            event(.toolCall, ["totally": "wrong shape"])
        ])

        guard case .unknown = try XCTUnwrap(items.first).body else {
            return XCTFail("expected the row to survive as unknown")
        }
    }

    func testIncrementalFoldMatchesBatchFold() throws {
        let events = [
            event(.sessionStarted, try SessionStartedPayload(title: "s").makePayload()),
            event(.turnStarted, try TurnStartedPayload(messageID: "m1", text: "hi").makePayload()),
            event(.requestComposed, try RequestComposedPayload(
                systemSections: [PromptSection(origin: .userSystemPrompt, label: "System", body: "Be terse.")]
            ).makePayload(), requestID: "r1"),
            event(.responseDelta, try ResponseDeltaPayload(content: "Par").makePayload(), requestID: "r1"),
            event(.toolCall, try ToolCallPayload(callID: "c1", name: "web_search").makePayload(), requestID: "r1"),
            event(.toolResult, try ToolResultPayload(callID: "c1", output: "ok").makePayload(), requestID: "r1"),
            event(.responseCompleted, try ResponseCompletedPayload(messageID: "a1", content: "Paris").makePayload(), requestID: "r1"),
            event(.turnEnded, try TurnEndedPayload(status: "completed", roundCount: 2).makePayload()),
        ]

        var incremental = TraceReducer()
        for event in events {
            incremental.apply(event)
        }

        XCTAssertEqual(incremental.items, TraceReducer.items(for: events))
    }

    private func event(
        _ kind: TraceEventKind,
        _ payload: TraceJSON,
        requestID: String? = nil
    ) -> TraceEvent {
        defer { seq += 1 }
        return TraceEvent(
            traceID: "t1",
            seq: seq,
            timestamp: base.addingTimeInterval(Double(seq)),
            kind: kind,
            scope: TraceScope(sessionID: "s1", turnID: "u1", requestID: requestID),
            payload: payload
        )
    }
}
