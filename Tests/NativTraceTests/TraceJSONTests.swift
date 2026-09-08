import XCTest
import NativTrace

final class TraceJSONTests: XCTestCase {
    func testCanonicalFormSortsKeysAndPreservesNumberKinds() throws {
        let value: TraceJSON = ["b": 2, "a": ["x": true, "y": [1, 2.5, "s", nil]]]

        XCTAssertEqual(
            try value.canonicalString(),
            #"{"a":{"x":true,"y":[1,2.5,"s",null]},"b":2}"#
        )
    }

    func testCanonicalisationIsIdempotent() throws {
        let value: TraceJSON = ["z": [1, 2, 3], "a": ["nested": ["deep": 1.5]]]
        let once = try value.canonicalString()
        let twice = try TraceJSON.decode(once).canonicalString()

        XCTAssertEqual(once, twice)
    }

    func testIntegersDoNotBecomeFloatingPoint() throws {
        let value = try TraceJSON.decode(#"{"tokens":1204}"#)

        XCTAssertEqual(value["tokens"]?.intValue, 1204)
        XCTAssertEqual(try value.canonicalString(), #"{"tokens":1204}"#)
    }

    func testAccessorsReturnNilForMismatchedTypes() {
        let value: TraceJSON = ["text": "hello"]

        XCTAssertEqual(value["text"]?.stringValue, "hello")
        XCTAssertNil(value["text"]?.intValue)
        XCTAssertNil(value["missing"])
        XCTAssertNil(value[0])
    }

    func testEncodingAnExistingCodableValue() throws {
        struct Payload: Encodable {
            let name: String
            let count: Int
        }

        let value = try TraceJSON(encoding: Payload(name: "web_search", count: 2))

        XCTAssertEqual(value["name"]?.stringValue, "web_search")
        XCTAssertEqual(value["count"]?.intValue, 2)
    }
}
