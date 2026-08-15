import XCTest

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testInitialComposerAndRequestStateIsIdle() {
        let subject = ChatViewModel()

        XCTAssertEqual(subject.draft, "")
        XCTAssertTrue(subject.pendingImageAttachments.isEmpty)
        XCTAssertFalse(subject.hasPendingRequests)
        XCTAssertFalse(subject.isCurrentSessionSending)
        XCTAssertTrue(subject.currentSessionQueuedPrompts.isEmpty)
    }

    func testCanSendRequiresRunningServerModelAndContent() {
        let subject = ChatViewModel()

        subject.draft = "Hello"

        XCTAssertFalse(subject.canSend(isRunning: false, selectedModelID: "model"))
        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: nil))
        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: ""))
        XCTAssertTrue(subject.canSend(isRunning: true, selectedModelID: "model"))

        subject.draft = "  \n  "

        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: "model"))
    }

    func testPendingAttachmentEnablesSendAndCanBeRemoved() {
        let subject = ChatViewModel()
        let attachment = ChatImageAttachment(
            filename: "reference.png",
            mimeType: "image/png",
            base64Data: ""
        )

        subject.stageAttachment(attachment)

        XCTAssertEqual(subject.pendingImageAttachments, [attachment])
        XCTAssertTrue(subject.canSend(isRunning: true, selectedModelID: "model"))

        subject.removePendingImageAttachment(attachment.id)

        XCTAssertTrue(subject.pendingImageAttachments.isEmpty)
        XCTAssertFalse(subject.canSend(isRunning: true, selectedModelID: "model"))
    }

    func testUnavailableReasonUsesServerAndModelPreconditions() {
        let subject = ChatViewModel()

        XCTAssertEqual(
            subject.unavailableReason(isRunning: false, selectedModelID: "model"),
            "Server is stopped."
        )
        XCTAssertEqual(
            subject.unavailableReason(isRunning: true, selectedModelID: nil),
            "Select a model in Models."
        )
        XCTAssertNil(subject.unavailableReason(isRunning: true, selectedModelID: "model"))
    }
}
