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
