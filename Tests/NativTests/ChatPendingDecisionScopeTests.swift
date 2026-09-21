import Foundation
import XCTest

final class ChatPendingDecisionScopeTests: XCTestCase {
    private let chatA = UUID()
    private let chatB = UUID()

    func testTheSoleDecisionInTheVisibleChatIsReturned() {
        let visible = UUID()
        let hidden = UUID()

        XCTAssertEqual(soleID(in: [visible: chatA, hidden: chatB], visible: chatA), visible)
    }

    func testDecisionsInOtherChatsAreNeverReturned() {
        XCTAssertNil(soleID(in: [UUID(): chatA], visible: chatB))
        XCTAssertNil(soleID(in: [UUID(): chatA], visible: nil))
    }

    func testAmbiguousOrEmptyPendingDecisionsAreNotReturned() {
        XCTAssertNil(soleID(in: [UUID(): chatA, UUID(): chatA], visible: chatA))
        XCTAssertNil(soleID(in: [:], visible: chatA))
    }

    private func soleID(in sessions: [UUID: UUID], visible: UUID?) -> UUID? {
        ChatPendingDecisionScope.soleID(in: sessions, matching: visible) { $0 }
    }
}
