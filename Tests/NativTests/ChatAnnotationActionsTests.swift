import AppKit
import SwiftUI
import XCTest

@MainActor
final class ChatAnnotationActionsTests: XCTestCase {
    func testActionsKeepTheirIdentityAndTargetTheOwningChat() {
        let first = ChatViewModel()
        let second = ChatViewModel()
        let actions = first.annotationActions
        let messageID = UUID()

        first.draft = "A changed draft"
        actions.navigate(to: messageID)

        XCTAssertTrue(actions === first.annotationActions)
        XCTAssertNotEqual(actions, second.annotationActions)
        XCTAssertEqual(first.scrollTargetMessageID, messageID)
        XCTAssertNil(second.scrollTargetMessageID)
    }

    func testRetainedActionsDoNotKeepAClosedChatAlive() {
        var chat: ChatViewModel? = ChatViewModel()
        weak var weakChat = chat
        let actions = chat!.annotationActions

        chat = nil

        XCTAssertNil(weakChat)
        actions.navigate(to: UUID())
        actions.remove(UUID())
    }

    func testEnvironmentConsumerSkipsUnrelatedUpdatesButReceivesCapacityAndOwnerChanges() {
        let first = ChatViewModel()
        let second = ChatViewModel()
        let record = RenderRecord()
        let host = NSHostingView(rootView: EnvironmentHost(chat: first, record: record))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        render(host)
        let initialEvaluations = record.evaluations
        let initialHostEvaluations = record.hostEvaluations
        XCTAssertGreaterThan(initialEvaluations, 0)
        XCTAssertTrue(record.actions === first.annotationActions)

        for draft in ["First update", "Second update", "Third update"] {
            first.draft = draft
            render(host)
        }
        XCTAssertGreaterThan(record.hostEvaluations, initialHostEvaluations)
        XCTAssertEqual(record.evaluations, initialEvaluations)

        host.rootView = EnvironmentHost(chat: first, record: record, canAdd: false)
        render(host)
        XCTAssertGreaterThan(record.evaluations, initialEvaluations)
        XCTAssertFalse(record.canAdd)

        host.rootView = EnvironmentHost(chat: second, record: record)
        render(host)
        XCTAssertTrue(record.actions === second.annotationActions)
        XCTAssertTrue(record.canAdd)
        let messageID = UUID()
        record.actions?.navigate(to: messageID)
        XCTAssertEqual(second.scrollTargetMessageID, messageID)
        XCTAssertNil(first.scrollTargetMessageID)
    }

    private func render(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class RenderRecord {
    var hostEvaluations = 0
    var evaluations = 0
    var actions: ChatAnnotationActions?
    var canAdd = true
}

private struct EnvironmentHost: View {
    @ObservedObject var chat: ChatViewModel
    let record: RenderRecord
    var canAdd = true

    var body: some View {
        record.hostEvaluations += 1
        return VStack {
            Text(chat.draft)
            EnvironmentConsumer(record: record)
        }
        .environment(\.chatAnnotationActions, chat.annotationActions)
        .environment(\.canAddChatAnnotation, canAdd)
    }
}

private struct EnvironmentConsumer: View {
    let record: RenderRecord
    @Environment(\.chatAnnotationActions) private var actions
    @Environment(\.canAddChatAnnotation) private var canAdd

    var body: some View {
        record.evaluations += 1
        record.actions = actions
        record.canAdd = canAdd
        return Text(canAdd && actions != nil ? "Quote reply available" : "Quotes unavailable")
    }
}
