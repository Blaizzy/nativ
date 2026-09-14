import XCTest
import NativTrace

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
        let payload: TraceJSON = .object([
            "knownField": .string("a"),
            "fieldFromTheFuture": .object(["deeply": .object(["nested": .int(7)])])
        ])

        let restored = try TraceJSON.decode(payload.canonicalString())

        guard case .object(let root) = restored,
              case .object(let future)? = root["fieldFromTheFuture"],
              case .object(let nested)? = future["deeply"],
              case .int(let value)? = nested["nested"]
        else {
            return XCTFail("nested value was not preserved")
        }
        XCTAssertEqual(value, 7)
    }

    func testTypedViewReadsKnownFieldsAndIgnoresTheRest() throws {
        let event = TraceEvent(
            traceID: "t", seq: 0, timestamp: Date(),
            kind: PartialView.kind,
            payload: .object(["knownField": .string("a"), "somethingElse": .array([.int(1), .int(2), .int(3)])])
        )

        XCTAssertEqual(PartialView(event: event)?.knownField, "a")
    }

    func testTypedViewRejectsEventsOfAnotherKind() throws {
        let event = TraceEvent(
            traceID: "t", seq: 0, timestamp: Date(),
            kind: .toolCall,
            payload: .object(["knownField": .string("a")])
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
