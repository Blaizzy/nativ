import XCTest

final class FormattingTests: XCTestCase {
    func testMissingValuesUseEmDash() {
        XCTAssertEqual(NativFormatting.rate(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.decimal(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.integer(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.milliseconds(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.seconds(fromMilliseconds: nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.gigabytes(fromBytes: nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.duration(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.timestamp(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.titleizedIdentifier(nil), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.missingValue, "—")
    }

    func testElapsedDurationUsesConsistentCompactUnits() {
        XCTAssertEqual(NativFormatting.elapsedDuration(42), "42s")
        XCTAssertEqual(NativFormatting.elapsedDuration(120), "2m 0s")
        XCTAssertEqual(NativFormatting.elapsedDuration(3_660), "1h 1m")
    }
}
