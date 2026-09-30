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
    @Published var composerWidth: CGFloat = 600
    var chatWidth: CGFloat = 0
}

private struct SplitFixture: View {
    @ObservedObject var state: SplitFixtureState

    var body: some View {
        ChatWorkSplitView(isWorkVisible: state.workVisible, isExpanded: $state.expanded,
                          onShowChatOnly: { state.workVisible = false }) {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.chatWidth = $0 }
                .preference(key: ChatComposerMinimumWidthKey.self, value: state.composerWidth)
        } work: {
            Color.clear
        }
    }
}
