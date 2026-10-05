import Foundation
import XCTest

final class LaunchSplashPreferencesTests: XCTestCase {
    func testUnviewedSplashIsAvailableBeforeCutoff() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-31T23:59:59Z"))
        XCTAssertTrue(LaunchSplashPreferences.shouldShow(hasViewed: false, now: now))
        XCTAssertFalse(LaunchSplashPreferences.shouldShow(hasViewed: true, now: now))
    }

    func testSplashExpiresOnNovemberFirst() throws {
        for timestamp in ["2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z"] {
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
            XCTAssertFalse(LaunchSplashPreferences.shouldShow(hasViewed: false, now: now))
            XCTAssertFalse(LaunchSplashPreferences.shouldShow(hasViewed: true, now: now))
        }
    }
}
