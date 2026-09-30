import AppKit
import SwiftUI
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
        }
    }
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
