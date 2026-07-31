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

    @discardableResult
    static func requestInsertTextAccess() -> Bool {
        CGRequestPostEventAccess()
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
    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
