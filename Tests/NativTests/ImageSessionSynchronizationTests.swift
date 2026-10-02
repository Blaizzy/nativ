import XCTest

@MainActor
final class ImageSessionSynchronizationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let hub = PersistedDataChangeHub()
        let store: ImageGenerationSessionStore

        init(_ sessions: [ImageGenerationSession]) throws {
            store = ImageGenerationSessionStore(
                imageDirectory: root.appendingPathComponent("Images"),
                mediaStore: MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
            )
            for session in sessions {
                guard store.saveSession(session) else { throw CocoaError(.fileWriteUnknown) }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func receiver(windowID: UUID = UUID()) -> ImageGenerationViewModel {
            ImageGenerationViewModel(windowID: windowID, persistedDataChanges: hub, sessionStore: store)
        }

        func notify(_ id: UUID) {
            hub.send(.imageGenerationSession(id), originWindowID: UUID())
        }
    }

    private func session(_ title: String, age: TimeInterval = 0) -> ImageGenerationSession {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + age)
        return ImageGenerationSession(
            id: UUID(), title: title, createdAt: date, updatedAt: date,
            modelKind: .imageGeneration, modelID: "test/model",
            draftSettings: ImageRequestSettings(), activeReference: nil, turns: []
        )
    }

    func testNotificationDoesNotReloadUnrelatedSessions() async throws {
        let selected = session("Selected", age: 2)
        let unrelated = session("Unrelated")
        var changed = session("Before", age: 1)
        let fixture = try Fixture([selected, unrelated, changed])
        defer { fixture.remove() }
        let receiver = fixture.receiver()
        receiver.selectSession(selected.id)
        receiver.prompt = "Keep my draft"
        // A full reload would drop this unreadable unrelated session.
        try Data("invalid JSON".utf8).write(to: fixture.store.sessionURL(for: unrelated.id))
        changed.title = "After"
        changed.updatedAt = selected.updatedAt.addingTimeInterval(1)
        XCTAssertTrue(fixture.store.saveSession(changed))

        fixture.notify(changed.id)

        XCTAssertEqual(receiver.sessions.map(\.id), [changed.id, selected.id, unrelated.id])
        XCTAssertEqual(receiver.sessions.first?.title, "After")
        XCTAssertEqual(receiver.currentSessionID, selected.id)
        XCTAssertEqual(receiver.prompt, "Keep my draft")
    }

    func testSelectedSessionUpdateReachesAllReceiversAndPreservesDraft() async throws {
        var changed = session("Original")
        let fixture = try Fixture([changed])
        defer { fixture.remove() }
        let receivers = (0..<3).map { _ in fixture.receiver() }
        for receiver in receivers {
            receiver.selectSession(changed.id)
            receiver.prompt = "Unsent prompt"
        }
        changed.draftSettings.steps = 12
        changed.modelID = "test/updated-model"
        XCTAssertTrue(fixture.store.saveSession(changed))

        fixture.notify(changed.id)

        for receiver in receivers {
            XCTAssertEqual(receiver.currentSessionID, changed.id)
            XCTAssertEqual(receiver.requestSettings.steps, 12)
            XCTAssertEqual(receiver.modelID, changed.modelID)
            XCTAssertEqual(receiver.prompt, "Unsent prompt")
        }
    }

    func testNewSessionIsInsertedOnceAndSorted() async throws {
        let original = session("Original")
        let fixture = try Fixture([original])
        defer { fixture.remove() }
        let receiver = fixture.receiver()
        receiver.selectSession(original.id)
        let added = session("New", age: 2)
        XCTAssertTrue(fixture.store.saveSession(added))

        fixture.notify(added.id)
        fixture.notify(added.id)

        XCTAssertEqual(receiver.sessions.map(\.id), [added.id, original.id])
        XCTAssertEqual(receiver.currentSessionID, original.id)
    }

    func testDeletingBackgroundSessionPreservesSelectionAndDraft() async throws {
        let current = session("Current", age: 1)
        let background = session("Background")
        let fixture = try Fixture([current, background])
        defer { fixture.remove() }
        let receiver = fixture.receiver()
        receiver.selectSession(current.id)
        receiver.prompt = "Keep this"

        fixture.store.deleteSession(id: background.id)
        fixture.notify(background.id)

        XCTAssertEqual(receiver.sessions.map(\.id), [current.id])
        XCTAssertEqual(receiver.currentSessionID, current.id)
        XCTAssertEqual(receiver.prompt, "Keep this")
    }

    func testDeletingSelectedSessionChoosesNewestRemaining() async throws {
        let current = session("Current", age: 3)
        let next = session("Next", age: 2)
        let oldest = session("Oldest")
        let fixture = try Fixture([current, next, oldest])
        defer { fixture.remove() }
        let receiver = fixture.receiver()
        receiver.selectSession(current.id)
        receiver.prompt = "Discard this"

        fixture.store.deleteSession(id: current.id)
        fixture.notify(current.id)

        XCTAssertEqual(receiver.sessions.map(\.id), [next.id, oldest.id])
        XCTAssertEqual(receiver.currentSessionID, next.id)
        XCTAssertTrue(receiver.prompt.isEmpty)
    }

    func testDeletingLastSessionClearsSelection() async throws {
        let current = session("Only")
        let fixture = try Fixture([current])
        defer { fixture.remove() }
        let receiver = fixture.receiver()
        receiver.selectSession(current.id)
        receiver.prompt = "Discard this"

        fixture.store.deleteSession(id: current.id)
        fixture.notify(current.id)

        XCTAssertTrue(receiver.sessions.isEmpty)
        XCTAssertNil(receiver.currentSessionID)
        XCTAssertTrue(receiver.turns.isEmpty)
        XCTAssertNil(receiver.activeReference)
        XCTAssertTrue(receiver.prompt.isEmpty)
    }

    func testOwnWindowAndChatNotificationsAreIgnored() async throws {
        var current = session("Original")
        let fixture = try Fixture([current])
        defer { fixture.remove() }
        let windowID = UUID()
        let receiver = fixture.receiver(windowID: windowID)
        current.title = "Changed"
        XCTAssertTrue(fixture.store.saveSession(current))

        fixture.hub.send(.imageGenerationSession(current.id), originWindowID: windowID)
        fixture.hub.send(.chatSession(current.id), originWindowID: UUID())

        XCTAssertEqual(receiver.sessions.first?.title, "Original")
        fixture.notify(current.id)
        XCTAssertEqual(receiver.sessions.first?.title, "Changed")
    }
}
