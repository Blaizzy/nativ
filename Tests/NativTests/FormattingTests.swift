import XCTest

final class FormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private let deDE = Locale(identifier: "de_DE")

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
        XCTAssertEqual(NativFormatting.elapsedDuration(42, locale: enUS), "42s")
        XCTAssertEqual(NativFormatting.elapsedDuration(120, locale: enUS), "2m 0s")
        XCTAssertEqual(NativFormatting.elapsedDuration(3_660, locale: enUS), "1h 1m")
    }

    func testClockDurationUsesSharedClockStyle() {
        XCTAssertEqual(NativFormatting.clockDuration(-1, locale: enUS), "0:00")
        XCTAssertEqual(NativFormatting.clockDuration(.nan, locale: enUS), "0:00")
        XCTAssertEqual(NativFormatting.clockDuration(5, locale: enUS), "0:05")
        XCTAssertEqual(NativFormatting.clockDuration(125, locale: enUS), "2:05")
        XCTAssertEqual(NativFormatting.clockDuration(3_661, locale: enUS), "1:01:01")
    }

    func testCompactCountsUseConsistentSuffixes() {
        XCTAssertEqual(NativFormatting.compactCount(999, locale: enUS).display, "999")
        XCTAssertEqual(NativFormatting.compactCount(1_000, locale: enUS).display, "1K")
        XCTAssertEqual(NativFormatting.compactCount(1_200, locale: enUS).display, "1.2K")
        XCTAssertEqual(NativFormatting.compactCount(1_000_000, locale: enUS).display, "1M")
        XCTAssertEqual(NativFormatting.compactCount(2_000_000_000, locale: enUS).display, "2B")
        XCTAssertEqual(NativFormatting.compactCount(-1_200, locale: enUS).display, "-1.2K")
    }

    func testValuesRespectTheDisplayLocale() {
        XCTAssertEqual(NativFormatting.decimal(12.5, fractionDigits: 1, locale: enUS), "12.5")
        XCTAssertEqual(NativFormatting.decimal(12.5, fractionDigits: 1, locale: deDE), "12,5")
        XCTAssertEqual(NativFormatting.rate(12.5, locale: enUS), "12.5 tok/s")
        XCTAssertEqual(NativFormatting.rate(12.5, locale: deDE), "12,5 tok/s")
        XCTAssertEqual(NativFormatting.gigabytes(1.5, locale: enUS), "1.50 GB")
    }

    func testInvalidDisplayValuesUseTheMissingValue() {
        XCTAssertEqual(NativFormatting.rate(0), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.rate(-1), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.rate(.nan), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.milliseconds(-1), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.duration(-1), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.gigabytes(-1), NativFormatting.missingValue)
        XCTAssertEqual(NativFormatting.percent(-1), NativFormatting.missingValue)
    }

    func testTruncatedModelNamesUseTypographicEllipsis() {
        let value = NativFormatting.truncateModelName(
            "organization/a-very-long-model-name-that-needs-to-be-shortened-for-display"
        )

        XCTAssertTrue(value.contains("…"))
        XCTAssertFalse(value.contains("..."))
    }
}
