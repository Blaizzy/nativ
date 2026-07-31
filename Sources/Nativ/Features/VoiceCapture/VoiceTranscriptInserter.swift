import AppKit
import ApplicationServices

struct VoiceTranscriptInsertionTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let applicationName: String?

    init(processIdentifier: pid_t, applicationName: String? = nil) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
    }
}

@MainActor
enum VoiceTranscriptInserter {
    private static let pasteKeyCode = CGKeyCode(9)

    static func captureTarget() -> VoiceTranscriptInsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return VoiceTranscriptInsertionTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName
        )
    }

    static func insertAtCursor(
        _ transcript: String,
        target: VoiceTranscriptInsertionTarget? = nil
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(transcript, forType: .string) else {
            return false
        }
        let hasInsertTextAccess =
            NativSystemPermissionController.hasInsertTextAccess()
            || NativSystemPermissionController.requestInsertTextAccess()
        guard hasInsertTextAccess else {
            return false
        }

        let targetApplication = target.flatMap {
            NSRunningApplication(processIdentifier: $0.processIdentifier)
        }
        if let targetApplication, !targetApplication.isActive {
            targetApplication.activate(options: [.activateIgnoringOtherApps])
        }

        do {
            try await Task.sleep(for: .milliseconds(targetApplication == nil ? 60 : 140))
        } catch {
            return false
        }

        guard let eventSource = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: pasteKeyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: pasteKeyCode,
                keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if let target {
            keyDown.postToPid(target.processIdentifier)
            do {
                try await Task.sleep(for: .milliseconds(18))
            } catch {
                return false
            }
            keyUp.postToPid(target.processIdentifier)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }
}
