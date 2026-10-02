import AppKit
import XCTest

@MainActor
final class ChatSelectionEventRouterTests: XCTestCase {
    func testMessagesShareRouterAndReleaseItWhenDetached() {
        weak var router: ChatSelectionEventRouter?
        autoreleasepool {
            let fixture = SelectionEventFixture(messageCount: 500)
            defer { fixture.close() }
            router = fixture.probes.first?.eventRouter
            XCTAssertNotNil(router)
            XCTAssertTrue(fixture.probes.allSatisfy { $0.eventRouter === router })
            fixture.probes.forEach { $0.removeFromSuperview() }
            XCTAssertTrue(fixture.probes.allSatisfy { $0.eventRouter == nil })
        }
        XCTAssertNil(router)
    }

    func testComposerTypingAndSelectionDoNoMessageSelectionWork() async throws {
        let fixture = SelectionEventFixture(messageCount: 500)
        defer { fixture.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.composer))
        await drainSelectionReads()
        fixture.resetCounts()
        for _ in 0..<20 {
            fixture.key(.keyDown, code: 0)
            fixture.key(.keyUp, code: 0)
        }
        fixture.key(.keyDown, code: 124, modifiers: .shift)
        fixture.key(.keyUp, code: 124, modifiers: .shift)
        fixture.key(.keyDown, code: 0, modifiers: .command)
        fixture.key(.keyUp, code: 0, modifiers: .command)
        // The composer overlaps the first probe's bounds, as with a floating composer.
        fixture.mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20))
        fixture.mouse(.leftMouseUp, at: NSPoint(x: 30, y: 20))
        await drainSelectionReads()
        XCTAssertEqual(fixture.root.hitCount, 0)
        XCTAssertEqual(fixture.message.rangeReads, 0)
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
    }

    func testMouseSelectionReadsOnlyTheMessageUnderThePointer() async throws {
        let fixture = SelectionEventFixture(messageCount: 500)
        defer { fixture.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.composer))
        fixture.resetCounts()
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseUp)
        fixture.mouse(.leftMouseUp) // A timer or duplicate mouse-up must not read it again.
        await drainSelectionReads()
        XCTAssertEqual(fixture.root.hitCount, 1)
        XCTAssertEqual(fixture.window.childWindows?.count, 1)
    }

    func testKeyboardSelectionStillShowsQuoteAndOrdinaryKeysDismissIt() async throws {
        let fixture = SelectionEventFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.message))
        fixture.resetCounts()
        for (code, modifiers): (UInt16, NSEvent.ModifierFlags) in [(124, .shift), (0, .command)] {
            fixture.key(.keyDown, code: code, modifiers: modifiers)
            fixture.key(.keyUp, code: code, modifiers: modifiers)
            await drainSelectionReads()
            XCTAssertEqual(fixture.window.childWindows?.count, 1)
        }
        XCTAssertGreaterThan(fixture.message.rangeReads, 0)
        fixture.resetCounts()
        fixture.key(.keyDown, code: 124)
        fixture.key(.keyUp, code: 124)
        await drainSelectionReads()
        XCTAssertEqual(fixture.message.rangeReads, 0)
        XCTAssertEqual(fixture.root.hitCount, 0)
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
    }

    func testNewInputCancelsPendingSelectionRead() async throws {
        let fixture = SelectionEventFixture()
        defer { fixture.close() }
        await drainSelectionReads()
        fixture.resetCounts()
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseUp)
        fixture.key(.keyDown, code: 0)
        await drainSelectionReads()
        XCTAssertEqual(fixture.root.hitCount, 0)
        XCTAssertEqual(fixture.message.rangeReads, 0)
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
    }

    func testKeyboardSelectionSupportsAccessibilityResponders() async {
        let fixture = SelectionEventFixture(messageCount: 500)
        defer { fixture.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.root))
        fixture.key(.keyDown, code: 124, modifiers: .shift)
        fixture.key(.keyUp, code: 124, modifiers: .shift)
        await drainSelectionReads()
        XCTAssertEqual(fixture.window.childWindows?.count, 1)
    }

    func testDisabledHiddenAndOffscreenMessagesAreSkipped() async throws {
        let fixture = SelectionEventFixture(messageCount: 500)
        defer { fixture.close() }
        let visible = try XCTUnwrap(fixture.probes.first)
        await drainSelectionReads()
        visible.enabled = false
        fixture.resetCounts()
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseUp)
        await drainSelectionReads()
        visible.enabled = true
        visible.isHidden = true
        fixture.mouse(.leftMouseDown)
        fixture.mouse(.leftMouseUp)
        await drainSelectionReads()
        XCTAssertEqual(fixture.root.hitCount, 0)
        XCTAssertEqual(fixture.message.rangeReads, 0)
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
    }

    func testMovingMessageToAnotherWindowReplacesRouterAndStopsOldEvents() async throws {
        let first = SelectionEventFixture()
        let second = SelectionEventFixture()
        defer { first.close(); second.close() }
        let probe = try XCTUnwrap(first.probes.first)
        weak var oldRouter = probe.eventRouter
        second.root.addSubview(probe)
        XCTAssertNil(oldRouter)
        XCTAssertTrue(probe.eventRouter === second.probes.first?.eventRouter)
        first.resetCounts()
        first.mouse(.leftMouseDown)
        first.mouse(.leftMouseUp)
        await drainSelectionReads()
        XCTAssertEqual(first.root.hitCount, 0)
    }

    private func drainSelectionReads() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class SelectionEventFixture {
    let window = SelectionEventWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
    let root = SelectionEventRoot(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let message = SelectionEventTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 200))
    let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
    var probes: [ChatSelectionObserver.Probe] = []

    init(messageCount: Int = 1) {
        message.string = "Select this passage"
        message.isEditable = false
        message.isSelectable = true
        root.addSubview(message)
        root.addSubview(composer)
        root.selectionTarget = message
        window.contentView = root
        for index in 0..<messageCount {
            let probe = ChatSelectionObserver.Probe(frame: NSRect(
                x: 0, y: index * 400, width: 400, height: 300
            ))
            probe.message = ChatTranscriptMessage(role: .assistant, content: message.string)
            probe.enabled = true
            root.addSubview(probe)
            probes.append(probe)
        }
        // A registered window number is required for NSEvent.window routing.
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        message.setSelectedRange(NSRange(location: 7, length: 4))
    }

    func resetCounts() {
        root.hitCount = 0
        message.rangeReads = 0
    }

    func key(_ type: NSEvent.EventType, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                    keyCode: code)!
        NSApplication.shared.sendEvent(event)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint = NSPoint(x: 20, y: 200)) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        NSApplication.shared.sendEvent(event)
    }

    func close() {
        probes.forEach { $0.stop() }
        window.close()
    }
}

@MainActor
private final class SelectionEventWindow: NSWindow {
    // Exercise NSApplication's real local monitors without entering native drag tracking.
    override func sendEvent(_ event: NSEvent) {}
}

@MainActor
private final class SelectionEventRoot: NSView {
    var selectionTarget: SelectionEventTextView?
    var hitCount = 0
    override var acceptsFirstResponder: Bool { true }
    override var accessibilityFocusedUIElement: Any? {
        let target: SelectionEventTextView? = MainActor.assumeIsolated { selectionTarget }
        return target
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let target: SelectionEventTextView? = MainActor.assumeIsolated {
            hitCount += 1
            return selectionTarget
        }
        return target
    }
}

@MainActor
private final class SelectionEventTextView: NSTextView {
    var rangeReads = 0
    override func selectedRange() -> NSRange {
        rangeReads += 1
        return super.selectedRange()
    }
}
