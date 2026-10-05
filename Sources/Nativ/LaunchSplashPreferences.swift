import Foundation

enum LaunchSplashPreferences {
    static let viewedKey = "hasViewedWorkspaceLaunchSplash2026"

    // November 1, 2026 at midnight UTC, regardless of the user's calendar.
    static let expirationDate = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 2026, month: 11, day: 1, hour: 0, minute: 0, second: 0
    ).date!

    static func shouldShow(hasViewed: Bool, now: Date) -> Bool {
        !hasViewed && now < expirationDate
    }
}
