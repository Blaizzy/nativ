import Combine
import XCTest

@MainActor
final class PersistedDataChangeHubTests: XCTestCase {
    func testBroadcastsPersistedChangesWithTheirOrigin() {
        let subject = PersistedDataChangeHub()
        let originWindowID = UUID()
        let chatSessionID = UUID()
        let imageSessionID = UUID()
        var receivedChanges: [PersistedDataChange] = []
        let cancellable = subject.changes.sink { change in
            receivedChanges.append(change)
        }

        subject.send(.chatSession(chatSessionID), originWindowID: originWindowID)
        subject.send(.chatFolders, originWindowID: originWindowID)
        subject.send(.imageGenerationSession(imageSessionID), originWindowID: originWindowID)

        XCTAssertEqual(receivedChanges, [
            PersistedDataChange(
                originWindowID: originWindowID,
                kind: .chatSession(chatSessionID)
            ),
            PersistedDataChange(originWindowID: originWindowID, kind: .chatFolders),
            PersistedDataChange(
                originWindowID: originWindowID,
                kind: .imageGenerationSession(imageSessionID)
            ),
        ])
        withExtendedLifetime(cancellable) {}
    }
}
