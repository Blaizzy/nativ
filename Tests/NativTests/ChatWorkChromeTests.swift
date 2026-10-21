import AppKit
import SwiftUI
import XCTest

@MainActor
final class ChatWorkChromeTests: XCTestCase {
    func testWindowDragOverlayYieldsToPaneControlsAsVisibilityChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = ChatViewModel(
            projectStore: ChatProjectStore(storageURL: root.appendingPathComponent("Projects.json")),
            sessionDirectory: root.appendingPathComponent("Chat")
        )
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<200 where chat.isLoadingSessions { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.isLoadingSessions)
        XCTAssertNotNil(chat.currentSessionID)

        let button = NSButton(title: "Pane control", target: nil, action: nil)
        let host = NSHostingView(rootView: ZStack {
            ChromeButtonFixture(button: button)
            HStack(spacing: 0) { ChatWorkWindowDragRegion(chat: chat, isChatWorkspace: true, height: 30) }
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        for visible in [false, true, false, true] {
            chat.setWorkPaneVisible(visible)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let parent = try XCTUnwrap(host.superview)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: parent)
            XCTAssertEqual(host.hitTest(point) === button, visible,
                           "Only closed-pane chrome should intercept clicks for window dragging")
        }
    }
}

private struct ChromeButtonFixture: NSViewRepresentable {
    let button: NSButton
    func makeNSView(context: Context) -> NSButton { button }
    func updateNSView(_ view: NSButton, context: Context) {}
}
