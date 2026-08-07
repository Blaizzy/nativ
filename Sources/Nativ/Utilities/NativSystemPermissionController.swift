import AppKit
import ApplicationServices
import AVFoundation

enum NativSystemPermissionController {
    @MainActor
    static func requestMicrophone(
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    static func hasInsertTextAccess() -> Bool {
        // macOS can authorize synthesized paste events through either the
        // dedicated Post Event service or the broader Accessibility grant
        // exposed in System Settings. Accept both forms of authorization.
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    static func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return CGRequestScreenCaptureAccess()
    }

    @discardableResult
    static func requestInsertTextAccess() -> Bool {
        if hasInsertTextAccess() {
            return true
        }

        // Posting the paste shortcut is covered by the Post Event service on
        // newer macOS releases, while Accessibility is still the permission
        // surfaced in System Settings and used on older releases. Request both
        // so a fresh or re-signed development build receives the native macOS
        // prompt instead of only being sent to a stale Settings entry.
        let postEventAccess = CGRequestPostEventAccess()
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let accessibilityAccess = AXIsProcessTrustedWithOptions(
            [promptKey: true] as CFDictionary
        )
        return postEventAccess || accessibilityAccess || hasInsertTextAccess()
    }

    @MainActor
    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @MainActor
    static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    @MainActor
    static func openScreenCaptureSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    @MainActor
    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum NativPermissionStatus: Equatable {
    case granted
    case notRequested
    case needsAttention
}

enum NativPermission: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            "Microphone"
        case .accessibility:
            "Accessibility"
        case .screenRecording:
            "Screen Recording"
        }
    }

    var summary: String {
        switch self {
        case .microphone:
            "Record your voice for dictation, voice notes, and meeting capture."
        case .accessibility:
            "Trigger the global dictation shortcut and insert transcripts at your cursor."
        case .screenRecording:
            "Capture system audio and attach screenshots to a chat."
        }
    }

    var systemImage: String {
        switch self {
        case .microphone:
            "mic.fill"
        case .accessibility:
            "accessibility"
        case .screenRecording:
            "record.circle"
        }
    }
}

@MainActor
final class NativPermissionStore: ObservableObject {
    @Published private(set) var statuses: [NativPermission: NativPermissionStatus] = [:]
    @Published private(set) var pendingPermission: NativPermission?

    private static let promptedDefaultsKey = "systemPermissionsPrompted.v1"

    private let defaults: UserDefaults
    private var promptedPermissions: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        promptedPermissions = Set(
            defaults.stringArray(forKey: Self.promptedDefaultsKey) ?? []
        )
        refresh()
    }

    var outstandingPermissions: [NativPermission] {
        NativPermission.allCases.filter { status(for: $0) != .granted }
    }

    var allGranted: Bool {
        outstandingPermissions.isEmpty
    }

    func status(for permission: NativPermission) -> NativPermissionStatus {
        statuses[permission] ?? .notRequested
    }

    func actionTitle(for permission: NativPermission) -> String {
        switch status(for: permission) {
        case .granted:
            "Granted"
        case .notRequested:
            pendingPermission == permission ? "Requesting…" : "Allow"
        case .needsAttention:
            "Open Settings"
        }
    }

    func refresh() {
        statuses = NativPermission.allCases.reduce(into: [:]) { result, permission in
            result[permission] = resolvedStatus(for: permission)
        }
    }

    func resolve(_ permission: NativPermission) {
        switch status(for: permission) {
        case .granted:
            return
        case .needsAttention:
            openSettings(for: permission)
        case .notRequested:
            prompt(permission)
        }
    }

    func openSettings(for permission: NativPermission) {
        switch permission {
        case .microphone:
            NativSystemPermissionController.openMicrophoneSettings()
        case .accessibility:
            NativSystemPermissionController.openAccessibilitySettings()
        case .screenRecording:
            NativSystemPermissionController.openScreenCaptureSettings()
        }
    }

    private func resolvedStatus(for permission: NativPermission) -> NativPermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notRequested
            default:
                return .needsAttention
            }
        case .accessibility:
            if NativSystemPermissionController.hasAccessibilityAccess() {
                return .granted
            }
            return hasPrompted(permission) ? .needsAttention : .notRequested
        case .screenRecording:
            if NativSystemPermissionController.hasScreenCaptureAccess() {
                return .granted
            }
            return hasPrompted(permission) ? .needsAttention : .notRequested
        }
    }

    private func prompt(_ permission: NativPermission) {
        guard pendingPermission == nil else { return }
        markPrompted(permission)

        switch permission {
        case .microphone:
            pendingPermission = permission
            NativSystemPermissionController.requestMicrophone { [weak self] _ in
                self?.pendingPermission = nil
                self?.refresh()
            }
        case .accessibility:
            NativSystemPermissionController.requestInsertTextAccess()
            refresh()
        case .screenRecording:
            NativSystemPermissionController.requestScreenCaptureAccess()
            refresh()
        }
    }

    private func hasPrompted(_ permission: NativPermission) -> Bool {
        promptedPermissions.contains(permission.rawValue)
    }

    private func markPrompted(_ permission: NativPermission) {
        guard promptedPermissions.insert(permission.rawValue).inserted else { return }
        defaults.set(Array(promptedPermissions), forKey: Self.promptedDefaultsKey)
    }
}
