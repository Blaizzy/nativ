import Foundation
import XCTest

final class LaunchSplashPreferencesTests: XCTestCase {
    func testUnviewedSplashIsAvailableBeforeCutoff() throws {
        let beforeCutoff = try date("2026-10-31T23:59:59Z")
        XCTAssertTrue(LaunchSplashPreferences.shouldShow(hasViewed: false, now: beforeCutoff))
        XCTAssertFalse(LaunchSplashPreferences.shouldShow(hasViewed: true, now: beforeCutoff))
    }

    func testSplashExpiresExactlyOnNovemberFirst() throws {
        for timestamp in ["2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z"] {
            let now = try date(timestamp)
            XCTAssertFalse(LaunchSplashPreferences.shouldShow(hasViewed: false, now: now))
            XCTAssertFalse(LaunchSplashPreferences.shouldShow(hasViewed: true, now: now))
        }
    }

    private func date(_ timestamp: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
    }
}
