import XCTest

@MainActor
final class ChatFolderMigrationTests: XCTestCase {
    func testFolderChatsAppearInSessionsFromCurrentAndLegacyStores() throws {
        let folderID = UUID()
        let folderMetadata = """
        [{"id":"\(folderID.uuidString)","name":"Old folder","isCollapsed":true,"isPinned":true}]
        """
        for usesLegacyCache in [false, true] {
            for metadata in [nil, folderMetadata, "invalid folder metadata"] as [String?] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let chatDirectory = root.appendingPathComponent("Chat")
                let legacyDirectory = root.appendingPathComponent("LegacyChat")
                let source = usesLegacyCache ? legacyDirectory : chatDirectory
                let sessionsDirectory = source.appendingPathComponent("Sessions")
                try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
                if let metadata {
                    try Data(metadata.utf8).write(to: source.appendingPathComponent("folders.json"))
                }

                let project = ChatProject(name: "Project", rootPath: root.path)
                let normal = session("Normal", age: 4)
                let grouped = session("In a folder", age: 3)
                let orphaned = session("Missing folder", age: 2)
                var pinned = session("Pinned", age: 1)
                pinned.pinned = true
                pinned.pinnedOrder = 2
                var projectChat = session("Project chat", age: 0)
                projectChat.projectID = project.id
                let expected = [projectChat, pinned, orphaned, grouped, normal]
                for chat in expected {
                    let id = chat.id == normal.id ? nil : (chat.id == orphaned.id ? UUID() : folderID)
                    try legacyData(chat, folderID: id).write(
                        to: sessionsDirectory.appendingPathComponent("\(chat.id.uuidString).json")
                    )
                }
                let store = ChatSessionStore(
                    chatDirectory: chatDirectory,
                    legacyChatDirectory: legacyDirectory,
                    mediaStore: MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
                )
                let loaded = store.loadSessions()
                XCTAssertEqual(loaded, expected)
                XCTAssertEqual(store.loadSessions(), expected, "Repeated migration must not duplicate chats")
                let sidebar = SidebarRecentsSnapshot(
                    chatSessions: loaded.map(\.summary), imageSessions: [], projects: [project]
                )
                XCTAssertEqual(sidebar.unpinnedSessions.compactMap(\.chatID), [orphaned.id, grouped.id, normal.id])
                XCTAssertEqual(sidebar.pinnedSessions.compactMap(\.chatID), [pinned.id])
                XCTAssertEqual(sidebar.sessions(inProject: project.id).compactMap(\.chatID), [projectChat.id])
                XCTAssertEqual(sidebar.recentSessions.count, expected.count)

                XCTAssertTrue(store.deleteSession(id: grouped.id))
                XCTAssertNil(store.loadSession(id: grouped.id))
                XCTAssertEqual(store.loadSessions().count, expected.count - 1)
            }
        }
    }

    func testSavingLegacyFolderChatDropsMembershipAndPreservesSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatSessionStore(
            chatDirectory: root.appendingPathComponent("Chat"),
            mediaStore: MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
        )
        var original = session("Conversation", age: 0)
        original.customTitle = "My conversation"
        original.sessionOrder = 7
        original.scheduledTaskID = "scheduled-task"
        original.personalizationSnapshot = "Original personalization"
        let url = store.sessionURL(for: original.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyData(original, folderID: UUID()).write(to: url)

        let loaded = try XCTUnwrap(store.loadSession(id: original.id))
        XCTAssertEqual(loaded, original)
        XCTAssertTrue(store.saveSession(loaded))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(saved["folderID"])
        let relaunched = ChatSessionStore(
            chatDirectory: root.appendingPathComponent("Chat"),
            mediaStore: MediaAssetStore(rootDirectory: root.appendingPathComponent("Media"))
        )
        XCTAssertEqual(relaunched.loadSessions(), [original])
    }

    func testLegacyFolderCollapseSettingIsIgnored() throws {
        let json = Data(#"{"sidebarFoldersCollapsed":false,"sidebarPinnedCollapsed":true,"sidebarProjectsCollapsed":true,"sidebarSessionsCollapsed":true}"#.utf8)
        let settings = try JSONDecoder().decode(NativSettings.self, from: json)
        XCTAssertTrue(settings.allSidebarSectionsCollapsed)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertNil(saved["sidebarFoldersCollapsed"])
    }

    private func session(_ title: String, age: TimeInterval) -> ChatSession {
        let date = Date(timeIntervalSince1970: 1_700_000_000 - age)
        return ChatSession(
            id: UUID(), title: title, createdAt: date, updatedAt: date,
            messages: [ChatTranscriptMessage(role: .user, content: title, createdAt: date)]
        )
    }

    private func legacyData(_ session: ChatSession, folderID: UUID?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
        json["folderID"] = folderID?.uuidString
        return try JSONSerialization.data(withJSONObject: json)
    }
}
