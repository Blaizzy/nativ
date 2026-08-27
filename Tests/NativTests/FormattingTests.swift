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
        XCTAssertEqual(NativFormatting.accessibleValue("—"), "Not available")
        XCTAssertEqual(NativFormatting.accessibleValue("42"), "42")
    }

    func testElapsedDurationUsesConsistentCompactUnits() {
        XCTAssertEqual(NativFormatting.elapsedDuration(42), "42s")
        XCTAssertEqual(NativFormatting.elapsedDuration(120), "2m 0s")
        XCTAssertEqual(NativFormatting.elapsedDuration(3_660), "1h 1m")
    }

    func testClockDurationUsesSharedClockStyle() {
        XCTAssertEqual(NativFormatting.clockDuration(-1), "0:00")
        XCTAssertEqual(NativFormatting.clockDuration(.nan), "0:00")
        XCTAssertEqual(NativFormatting.clockDuration(5), "0:05")
        XCTAssertEqual(NativFormatting.clockDuration(125), "2:05")
        XCTAssertEqual(NativFormatting.clockDuration(3_661), "1:01:01")
    }

    func testCompactCountsUseConsistentSuffixes() {
        XCTAssertEqual(NativFormatting.compactCount(999).display, "999")
        XCTAssertEqual(NativFormatting.compactCount(1_000).display, "1K")
        XCTAssertEqual(NativFormatting.compactCount(1_200).display, "1.2K")
        XCTAssertEqual(NativFormatting.compactCount(1_000_000).display, "1M")
        XCTAssertEqual(NativFormatting.compactCount(2_000_000_000).display, "2B")
    }

    func testTruncatedModelNamesUseTypographicEllipsis() {
        let value = NativFormatting.truncateModelName(
            "organization/a-very-long-model-name-that-needs-to-be-shortened-for-display"
        )

        XCTAssertTrue(value.contains("…"))
        XCTAssertFalse(value.contains("..."))
    }
}
