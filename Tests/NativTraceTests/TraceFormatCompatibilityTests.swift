import XCTest
import NativTrace

/// The trace format has to outlive the build that wrote it. These tests pin the
/// properties that make that true; a change that breaks one of them is a format
/// break, not a refactor.
final class TraceFormatCompatibilityTests: XCTestCase {
    private struct PartialView: TracePayloadView, Codable {
        static let kind = TraceEventKind(rawValue: "kind_from_the_future")
        var knownField: String?
    }

    func testUnknownEventKindDecodesInsteadOfFailing() throws {
        let encoded = try JSONEncoder().encode(TraceEventKind(rawValue: "invented_later"))
        let decoded = try JSONDecoder().decode(TraceEventKind.self, from: encoded)

        XCTAssertEqual(decoded.rawValue, "invented_later")
    }

    func testUnrecognisedPayloadFieldsSurviveRoundTrip() throws {
        let payload: TraceJSON = [
            "knownField": "a",
            "fieldFromTheFuture": ["deeply": ["nested": 7]],
        ]

        let restored = try TraceJSON.decode(payload.canonicalString())

        XCTAssertEqual(restored["fieldFromTheFuture"]?["deeply"]?["nested"]?.intValue, 7)
    }

    func testTypedViewReadsKnownFieldsAndIgnoresTheRest() throws {
        let event = TraceEvent(
            traceID: "t", seq: 0, timestamp: Date(),
            kind: PartialView.kind,
            payload: ["knownField": "a", "somethingElse": [1, 2, 3]]
        )

        XCTAssertEqual(PartialView(event: event)?.knownField, "a")
    }

    func testTypedViewRejectsEventsOfAnotherKind() throws {
        let event = TraceEvent(
            traceID: "t", seq: 0, timestamp: Date(),
            kind: .toolCall,
            payload: ["knownField": "a"]
        )

        XCTAssertNil(PartialView(event: event))
    }

    func testEventOrderingIsTotal() {
        let early = TraceEvent(traceID: "a", seq: 5, timestamp: Date(timeIntervalSince1970: 1), kind: .turnStarted)
        let late = TraceEvent(traceID: "a", seq: 6, timestamp: Date(timeIntervalSince1970: 0), kind: .turnStarted)

        XCTAssertTrue(TraceEvent.ordered(early, late), "sequence wins within one trace")

        let otherTrace = TraceEvent(traceID: "b", seq: 0, timestamp: Date(timeIntervalSince1970: 2), kind: .turnStarted)
        XCTAssertTrue(TraceEvent.ordered(early, otherTrace), "timestamp wins across traces")
    }
}
