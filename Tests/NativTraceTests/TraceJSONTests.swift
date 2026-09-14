import XCTest
import NativTrace

final class TraceJSONTests: XCTestCase {
    func testCanonicalFormSortsKeysAndPreservesNumberKinds() throws {
        let value: TraceJSON = .object([
            "b": .int(2),
            "a": .object(["x": .bool(true), "y": .array([.int(1), .double(2.5), .string("s"), .null])])
        ])

        XCTAssertEqual(
            try value.canonicalString(),
            #"{"a":{"x":true,"y":[1,2.5,"s",null]},"b":2}"#
        )
    }

    func testCanonicalisationIsIdempotent() throws {
        let value: TraceJSON = .object([
            "z": .array([.int(1), .int(2), .int(3)]),
            "a": .object(["nested": .object(["deep": .double(1.5)])])
        ])
        let once = try value.canonicalString()
        let twice = try TraceJSON.decode(once).canonicalString()

        XCTAssertEqual(once, twice)
    }

    func testIntegersDoNotBecomeFloatingPoint() throws {
        let value = try TraceJSON.decode(#"{"tokens":1204}"#)

        guard case .object(let fields) = value, case .int(let tokens)? = fields["tokens"] else {
            return XCTFail("integer token count was not preserved")
        }
        XCTAssertEqual(tokens, 1204)
        XCTAssertEqual(try value.canonicalString(), #"{"tokens":1204}"#)
    }

    func testEncodingAnExistingCodableValue() throws {
        struct Payload: Encodable {
            let name: String
            let count: Int
        }

        let value = try TraceJSON(encoding: Payload(name: "web_search", count: 2))

        guard case .object(let fields) = value,
              case .string(let name)? = fields["name"],
              case .int(let count)? = fields["count"]
        else {
            return XCTFail("encoded value was not decoded")
        }
        XCTAssertEqual(name, "web_search")
        XCTAssertEqual(count, 2)
    }
}
