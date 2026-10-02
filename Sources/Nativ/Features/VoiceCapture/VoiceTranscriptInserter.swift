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
    private static let returnKeyCode = CGKeyCode(36)

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
        target: VoiceTranscriptInsertionTarget? = nil,
        pressReturn: Bool = false
    ) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        // A command-only dictation must not paste an empty string over selected text.
        if !transcript.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(transcript, forType: .string) else {
                return false
            }
        } else if !pressReturn {
            return true
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
            targetApplication.activate()
        }

        do {
            try await Task.sleep(for: .milliseconds(targetApplication == nil ? 60 : 140))
        } catch {
            return false
        }

        if !transcript.isEmpty {
            guard await postKeyPress(pasteKeyCode, flags: .maskCommand, target: target) else {
                return false
            }
        }
        if pressReturn {
            if !transcript.isEmpty {
                // Give the target app time to consume the clipboard before Return.
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return false
                }
            }
            return await postKeyPress(returnKeyCode, flags: [], target: target)
        }
        return true
    }

    private static func postKeyPress(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags,
        target: VoiceTranscriptInsertionTarget?
    ) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard let eventSource = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: keyCode,
                keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        if let target {
            keyDown.postToPid(target.processIdentifier)
            do {
                try await Task.sleep(for: .milliseconds(18))
            } catch {
                // Always release a key that was posted, even if dictation was cancelled.
                keyUp.postToPid(target.processIdentifier)
                return false
            }
            keyUp.postToPid(target.processIdentifier)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return !Task.isCancelled
    }
}
