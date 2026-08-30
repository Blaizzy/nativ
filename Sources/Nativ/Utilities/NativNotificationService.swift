import AppKit
import Combine
import OSLog
import UserNotifications

struct NativNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let metadata: [String: String]
    let playsSound: Bool

    init(
        identifier: String = UUID().uuidString,
        title: String,
        body: String,
        metadata: [String: String] = [:],
        playsSound: Bool = true
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.metadata = metadata
        self.playsSound = playsSound
    }
}

enum NativNotificationAuthorizationStatus: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized, .provisional, .ephemeral:
            self = .authorized
        @unknown default:
            self = .unknown
        }
    }
}

@MainActor
final class NativNotificationService: ObservableObject {
    static let shared = NativNotificationService()

    @Published private(set) var authorizationStatus: NativNotificationAuthorizationStatus = .unknown
    @Published private(set) var isRequestingAuthorization = false

    private let center: UNUserNotificationCenter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Nativ",
        category: "Notifications"
    )
    private var refreshTask: Task<Void, Never>?

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        refreshAuthorizationStatus()
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    func refreshAuthorizationStatus() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let settings = await center.notificationSettings()
            guard !Task.isCancelled else { return }
            authorizationStatus = NativNotificationAuthorizationStatus(
                settings.authorizationStatus
            )
        }
    }

    func requestAuthorization() {
        guard authorizationStatus == .notDetermined,
              !isRequestingAuthorization
        else {
            return
        }

        isRequestingAuthorization = true
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
            }
            let settings = await center.notificationSettings()
            authorizationStatus = NativNotificationAuthorizationStatus(
                settings.authorizationStatus
            )
            isRequestingAuthorization = false
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else {
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func deliver(_ notification: NativNotification) async -> Bool {
        let settings = await center.notificationSettings()
        authorizationStatus = NativNotificationAuthorizationStatus(
            settings.authorizationStatus
        )
        guard isAuthorized else { return false }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.userInfo = notification.metadata
        if notification.playsSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            logger.error("Notification delivery failed: \(error.localizedDescription)")
            return false
        }
    }
}
