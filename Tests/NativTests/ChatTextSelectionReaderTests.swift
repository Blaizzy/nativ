import AppKit
import XCTest

@MainActor
final class ChatTextSelectionReaderTests: XCTestCase {
    func testSelectionProxyDoesNotNeedProtocolConformance() throws {
        let proxy = SelectionProxy()
        let selection = try XCTUnwrap(ChatTextSelectionReader.selection(from: proxy))
        XCTAssertEqual(selection.text, "passage")
        XCTAssertEqual(selection.range, NSRange(location: 4, length: 7))
        XCTAssertEqual(selection.frame, NSRect(x: 100, y: 200, width: 8, height: 16))
    }

    func testServicesReadsNativeSelectionWithoutChangingGeneralClipboard() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        text.string = "Before. Selected passage. After."
        text.isEditable = false
        window.contentView = text
        XCTAssertTrue(window.makeFirstResponder(text))
        text.setSelectedRange((text.string as NSString).range(of: "Selected passage"))
        let clipboardVersion = NSPasteboard.general.changeCount
        XCTAssertEqual(ChatTextSelectionReader.servicesSelection(in: window), "Selected passage")
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardVersion)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(ChatTextSelectionReader.servicesSelection(in: window))
    }

    func testUnsupportedAccessibilityObjectDoesNotCrash() {
        XCTAssertNil(ChatTextSelectionReader.selection(from: NSObject()))
        _ = ChatTextSelectionReader.focusedElement(of: NSObject())
        _ = ChatTextSelectionReader.focusedElement(of: NSApplication.shared)
    }

    func testNativeSelectionPreservesRepeatedPassageRange() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        text.string = "first yes; second yes"
        text.isEditable = false
        text.isSelectable = true
        window.contentView = text
        XCTAssertTrue(window.makeFirstResponder(text))
        let range = (text.string as NSString).range(of: "yes", options: .backwards)
        text.setSelectedRange(range)
        let selection = try XCTUnwrap(ChatTextSelectionReader.selection(in: window))
        XCTAssertEqual(selection.text, "yes")
        XCTAssertEqual(selection.range, range)
        XCTAssertEqual(selection.fullText, text.string)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(ChatTextSelectionReader.selection(in: window))
    }

    func testEmptyWindowSelectionDoesNotCrash() {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        XCTAssertNil(ChatTextSelectionReader.selection(in: window))
    }

    func testMessageSelectionIsReadWhileEmptyComposerKeepsFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = SelectionRoot(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let message = NSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 200))
        message.string = "Select this passage"
        message.isEditable = false
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        root.addSubview(message)
        root.addSubview(composer)
        root.selectionTarget = message
        window.contentView = root
        XCTAssertTrue(window.makeFirstResponder(composer))
        message.setSelectedRange(NSRange(location: 7, length: 4))
        let selection = try XCTUnwrap(ChatTextSelectionReader.selection(in: window, at: .zero))
        XCTAssertEqual(selection.text, "this")
        XCTAssertEqual(selection.range, NSRange(location: 7, length: 4))
        XCTAssertGreaterThan(selection.frame.height, 0)
        XCTAssertLessThan(selection.frame.height, message.frame.height)
    }
}

@MainActor
private final class SelectionRoot: NSView {
    var selectionTarget: NSObject?
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { selectionTarget }
}

@MainActor
private final class SelectionProxy: NSObject {
    @objc func accessibilitySelectedText() -> String { "passage" }
    @objc func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 4, length: 7) }
    @objc func accessibilityValue() -> Any? { "The passage here" }
    @objc(accessibilityFrameForRange:)
    func selectionFrame(_ range: NSRange) -> NSRect { NSRect(x: 100, y: 200, width: 8, height: 16) }
}
