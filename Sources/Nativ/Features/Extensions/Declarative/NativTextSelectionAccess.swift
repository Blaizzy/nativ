import AppKit
import ApplicationServices

/// Reads and writes the user's current text selection through the
/// accessibility API.
///
/// Nothing here is unit-testable — every call is a syscall into another
/// process — so it is kept to the two entry points the workflow services need.
@MainActor
enum NativTextSelectionAccess {
    static func read() -> NativTextSelection? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let element = focused else {
            return nil
        }
        let focusedElement = element as! AXUIElement

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selected
        ) == .success,
            let text = selected as? String,
            !text.isEmpty
        else {
            return nil
        }

        return NativTextSelection(
            text: text,
            target: frontmostTarget(),
            origin: NativSelectionOrigin(
                element: focusedElement,
                range: selectedRange(of: focusedElement)
            )
        )
    }

    /// Writes over the selection in place where the app supports it, and pastes
    /// otherwise.
    ///
    /// Pasting is the fallback rather than the primary path because it replaces
    /// only while a selection is still live — after a slow model call the
    /// caret may have moved, and the user would get their text duplicated
    /// rather than rewritten.
    static func replace(_ text: String, selection: NativTextSelection) async -> Bool {
        if let origin = selection.origin,
           let element = origin.element,
           writeInPlace(text, element: element as! AXUIElement, range: origin.range) {
            return true
        }
        return await pasteRestoringPasteboard(text, target: selection.target)
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func writeInPlace(
        _ text: String,
        element: AXUIElement,
        range: NSRange?
    ) -> Bool {
        if let range {
            var cfRange = CFRange(location: range.location, length: range.length)
            if let value = AXValueCreate(.cfRange, &cfRange) {
                _ = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    value
                )
            }
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    /// `VoiceTranscriptInserter` leaves the replacement on the pasteboard,
    /// which is acceptable for dictation the user just spoke but not for text
    /// an extension rewrote behind them.
    private static func pasteRestoringPasteboard(
        _ text: String,
        target: VoiceTranscriptInsertionTarget?
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                contents[type] = item.data(forType: type)
            }
            return contents
        }

        let inserted = await VoiceTranscriptInserter.insertAtCursor(text, target: target)

        // Only restore if nothing else has written since our paste, so we never
        // clobber something the user copied in the meantime.
        if let saved, !saved.isEmpty {
            pasteboard.clearContents()
            for contents in saved {
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: type)
                }
                pasteboard.writeObjects([item])
            }
        }
        return inserted
    }

    private static func frontmostTarget() -> VoiceTranscriptInsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return VoiceTranscriptInsertionTarget(
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName
        )
    }
}
