import AppKit
import SwiftUI
import WebKit
import XCTest

final class ChatWorkSplitTests: XCTestCase {
    func testDividerStopsBeforeControlsCompressThenCollapsesPastThreshold() {
        let sizing = ChatWorkSplitSizing(minimumChatWidth: 520)
        XCTAssertEqual(sizing.chatWidth(preferred: 505, available: 1_200), 520)
        XCTAssertFalse(sizing.shouldCollapse(proposed: 505, available: 1_200))
        XCTAssertTrue(sizing.shouldCollapse(proposed: 495, available: 1_200))
    }

    func testLongerModelControlsRaiseTheStableWidth() {
        let sizing = ChatWorkSplitSizing(minimumChatWidth: 640)
        XCTAssertEqual(sizing.chatWidth(preferred: nil, available: 1_200), 640)
        XCTAssertTrue(sizing.shouldCollapse(proposed: 600, available: 1_200))
        XCTAssertFalse(sizing.canSplit(960))
        XCTAssertTrue(sizing.canSplit(961))
    }

    func testWorkPaneMinimumAndPreviousChatWidthArePreserved() {
        let sizing = ChatWorkSplitSizing()
        XCTAssertEqual(sizing.chatWidth(preferred: 650, available: 1_200), 650)
        XCTAssertEqual(sizing.chatWidth(preferred: 1_100, available: 1_200), 879)
        XCTAssertTrue(sizing.shouldCollapse(proposed: 650, available: 800))
        XCTAssertTrue(sizing.canSplit(801))
    }
}

@MainActor
final class ChatWorkSplitViewTests: XCTestCase {
    func testDividerOwnsHitTestingAndCursorUpdatesInBothPaneOrders() async throws {
        let state = SplitFixtureState()
        let host = NSHostingView(rootView: SplitFixture(state: state, usesWebContent: true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let previousCursor = NSCursor.current
        defer { previousCursor.set(); window.close() }
        window.contentView = host
        window.orderBack(nil)

        for workOnLeft in [false, true] {
            state.workOnLeft = workOnLeft
            try await Task.sleep(for: .milliseconds(100))
            let divider = try XCTUnwrap(findDivider(in: host))
            let parent = try XCTUnwrap(host.superview)
            divider.updateTrackingAreas()
            XCTAssertTrue(divider.trackingAreas.contains { $0.options.contains(.cursorUpdate) })

            for (point, expected) in [(NSPoint(x: 11, y: 30), NSCursor.resizeLeftRight),
                                      (NSPoint(x: 21, y: 30), NSCursor.resizeLeftRight),
                                      (NSPoint(x: 16, y: divider.bounds.midY), NSCursor.pointingHand)] {
                let location = divider.convert(point, to: nil)
                let hit = host.hitTest(parent.convert(location, from: nil))
                // A background cursor helper used to lose this hit to SwiftUI.
                XCTAssertTrue(hit === divider, "The divider must own the cursor event")
                NSCursor.arrow.set()
                hit?.cursorUpdate(with: mouseEvent(.mouseMoved, at: location, in: window))
                XCTAssertEqual(NSCursor.current, expected)
            }

            let outside = divider.convert(NSPoint(x: 1, y: 30), to: parent)
            XCTAssertFalse(host.hitTest(outside) === divider, "Leave adjacent content interactive")
        }

        state.expanded = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(findDivider(in: host), "No invisible cursor target over the full document")
    }

    func testNativeDividerSeparatesSwapClicksFromResizeDrags() {
        let divider = ChatWorkDividerNSView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 32, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = divider
        let previousCursor = NSCursor.current
        defer { previousCursor.set(); window.close() }
        var swaps = 0
        var translations: [CGFloat] = []
        var dragEnds = 0
        divider.onSwap = { swaps += 1 }
        divider.onDrag = { translations.append($0) }
        divider.onDragEnded = { dragEnds += 1 }
        let center = divider.convert(NSPoint(x: 16, y: divider.bounds.midY), to: nil)

        divider.mouseDown(with: mouseEvent(.leftMouseDown, at: center, in: window))
        divider.mouseUp(with: mouseEvent(.leftMouseUp, at: center, in: window))
        XCTAssertEqual(swaps, 1)

        divider.mouseDown(with: mouseEvent(.leftMouseDown, at: center, in: window))
        let dragged = NSPoint(x: center.x + 10, y: center.y)
        divider.mouseDragged(with: mouseEvent(.leftMouseDragged, at: dragged, in: window))
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
        divider.mouseUp(with: mouseEvent(.leftMouseUp, at: dragged, in: window))
        XCTAssertEqual(translations, [10])
        XCTAssertEqual(dragEnds, 1)
        XCTAssertEqual(swaps, 1, "Releasing a drag over the button must not also swap")
    }

    private func findDivider(in view: NSView) -> ChatWorkDividerNSView? {
        if let divider = view as? ChatWorkDividerNSView { return divider }
        return view.subviews.lazy.compactMap { self.findDivider(in: $0) }.first
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }

    func testSwappingPreservesPaneWidthsAndViewState() async throws {
        let state = SplitFixtureState()
        state.composerWidth = 700
        let host = NSHostingView(rootView: SplitFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        let chatIdentity = try XCTUnwrap(state.chatIdentity)
        let workIdentity = try XCTUnwrap(state.workIdentity)
        let chatFrame = state.chatFrame
        let workFrame = state.workFrame
        XCTAssertLessThan(chatFrame.minX, workFrame.minX)

        state.workOnLeft = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.expanded)
        XCTAssertLessThan(state.workFrame.minX, state.chatFrame.minX)
        XCTAssertEqual(state.chatFrame.width, chatFrame.width, accuracy: 1)
        XCTAssertEqual(state.workFrame.width, workFrame.width, accuracy: 1)
        XCTAssertEqual(state.chatFrame.minX - state.workFrame.maxX, 1, accuracy: 1)
        XCTAssertEqual(state.chatIdentity, chatIdentity)
        XCTAssertEqual(state.workIdentity, workIdentity)

        state.workOnLeft = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.chatFrame, chatFrame)
        XCTAssertEqual(state.workFrame, workFrame)
        XCTAssertEqual(state.chatIdentity, chatIdentity)
        XCTAssertEqual(state.workIdentity, workIdentity)
    }

    func testWindowResizeCollapsesBeforeCompressingComposerAndCanRestoreChat() async throws {
        let state = SplitFixtureState()
        let host = NSHostingView(rootView: SplitFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_200, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.expanded)
        XCTAssertEqual(state.chatWidth, 600, accuracy: 1)

        // A larger model label changes the actual stable width, without a drag.
        state.composerWidth = 700
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.expanded)
        XCTAssertEqual(state.chatWidth, 700, accuracy: 1)

        window.setContentSize(CGSize(width: 1_000, height: 700))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.expanded)

        // Restoring chat in a window too small for both panes gives chat the space.
        state.expanded = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.workVisible)
        XCTAssertEqual(state.chatWidth, 1_000, accuracy: 1)
    }
}

@MainActor
private final class SplitFixtureState: ObservableObject {
    @Published var expanded = false
    @Published var workVisible = true
    @Published var workOnLeft = false
    @Published var composerWidth: CGFloat = 600
    var chatFrame: CGRect = .zero
    var workFrame: CGRect = .zero
    var chatWidth: CGFloat { chatFrame.width }
    var chatIdentity: UUID?
    var workIdentity: UUID?
}

private struct SplitFixture: View {
    @ObservedObject var state: SplitFixtureState
    var usesWebContent = false

    var body: some View {
        ChatWorkSplitView(isWorkVisible: state.workVisible, isExpanded: $state.expanded,
                          isWorkOnLeft: $state.workOnLeft,
                          onShowChatOnly: { state.workVisible = false }) {
            SplitFixturePane { frame, identity in
                state.chatFrame = frame
                state.chatIdentity = identity
            }
            .preference(key: ChatComposerMinimumWidthKey.self, value: state.composerWidth)
        } work: {
            SplitFixturePane { frame, identity in
                state.workFrame = frame
                state.workIdentity = identity
            }
            .background { if usesWebContent { SplitFixtureWebView() } }
        }
    }
}

private struct SplitFixtureWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct SplitFixturePane: View {
    @State private var identity = UUID()
    let record: (CGRect, UUID) -> Void

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                record($0, identity)
            }
    }
}
