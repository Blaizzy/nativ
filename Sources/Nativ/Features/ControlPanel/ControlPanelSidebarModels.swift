import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

/// Precomputes the merged recents index so the sidebar does not repeatedly map,
/// merge, filter, and sort sessions during view evaluation.
struct SidebarRecentsSnapshot: Equatable {
    let recentSessions: [ControlPanelRecentSession]
    let pinnedSessions: [ControlPanelRecentSession]
    let unpinnedSessions: [ControlPanelRecentSession]
    let ungroupedSessions: [ControlPanelRecentSession]
    let folders: [ChatFolder]
    let pinnedFolders: [ChatFolder]
    let unpinnedFolders: [ChatFolder]
    private let sessionsByFolder: [UUID: [ControlPanelRecentSession]]
    private let chatSessionIDs: Set<UUID>
    private let imageSessionIDs: Set<UUID>

    init(
        chatSessions: [ChatSessionSummary],
        folders: [ChatFolder],
        imageSessions: [ImageGenerationSessionSummary]
    ) {
        let recentSessions =
            (chatSessions.map(ControlPanelRecentSession.init(chat:))
            + imageSessions.map(ControlPanelRecentSession.init(imageGeneration:))).sorted(
                by: ControlPanelRecentSession.recencySort)
        let pinnedSessions =
            recentSessions
            .filter(\.pinned)
            .sorted(by: ControlPanelRecentSession.pinnedSort)
        let unpinnedSessions =
            recentSessions
            .filter { !$0.pinned }
            .sorted(by: ControlPanelRecentSession.sessionSort)
        let folderIDs = Set(folders.map(\.id))

        self.recentSessions = recentSessions
        self.pinnedSessions = pinnedSessions
        self.unpinnedSessions = unpinnedSessions
        ungroupedSessions = unpinnedSessions.filter { recent in
            guard let folderID = recent.folderID else { return true }
            return !folderIDs.contains(folderID)
        }
        self.folders = folders
        pinnedFolders = folders.filter(\.isPinned)
        unpinnedFolders = folders.filter { !$0.isPinned }
        var sessionsByFolder: [UUID: [ControlPanelRecentSession]] = [:]
        for recent in unpinnedSessions {
            guard let folderID = recent.folderID else { continue }
            sessionsByFolder[folderID, default: []].append(recent)
        }
        self.sessionsByFolder = sessionsByFolder
        chatSessionIDs = Set(chatSessions.map(\.id))
        imageSessionIDs = Set(imageSessions.map(\.id))
    }

    func sessions(inFolder folderID: UUID) -> [ControlPanelRecentSession] {
        sessionsByFolder[folderID] ?? []
    }

    func containsChatSession(_ sessionID: UUID) -> Bool {
        chatSessionIDs.contains(sessionID)
    }

    func containsImageSession(_ sessionID: UUID) -> Bool {
        imageSessionIDs.contains(sessionID)
    }

    func chatTitle(for sessionID: UUID) -> String? {
        recentSessions.first { $0.chatID == sessionID }?.title
    }
}

/// Exposes only the session index consumed by the control-panel sidebar. The
/// transcript, composer, attachment, streaming, and tool state remain observed
/// exclusively by `ChatView` and cannot invalidate the recents surface.
@MainActor
final class ChatSidebarState: ObservableObject {
    @Published private(set) var recents: SidebarRecentsSnapshot
    @Published private(set) var currentChatSessionID: UUID?
    @Published private(set) var currentImageSessionID: UUID?
    @Published private(set) var isGeneratingImage: Bool

    init(chat: ChatViewModel, imageGeneration: ImageGenerationViewModel) {
        recents = SidebarRecentsSnapshot(
            chatSessions: chat.sessions,
            folders: chat.folders,
            imageSessions: imageGeneration.sessions
        )
        currentChatSessionID = chat.currentSessionID
        currentImageSessionID = imageGeneration.currentSessionID
        isGeneratingImage = imageGeneration.isGenerating

        Publishers.CombineLatest3(
            chat.$sessions.removeDuplicates(),
            chat.$folders.removeDuplicates(),
            imageGeneration.$sessions.removeDuplicates()
        )
        .map { sessions, folders, imageSessions in
            SidebarRecentsSnapshot(
                chatSessions: sessions,
                folders: folders,
                imageSessions: imageSessions
            )
        }
        .removeDuplicates()
        .assign(to: &$recents)
        chat.$currentSessionID
            .removeDuplicates()
            .assign(to: &$currentChatSessionID)
        imageGeneration.$currentSessionID
            .removeDuplicates()
            .assign(to: &$currentImageSessionID)
        imageGeneration.$isGenerating
            .removeDuplicates()
            .assign(to: &$isGeneratingImage)
    }
}

enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case extensionPage(String)
    case chat(UUID)
    case imageGeneration(UUID)
}

struct ControlPanelRecentSession: Identifiable, Equatable {
    enum ID: Hashable {
        case chat(UUID)
        case imageGeneration(UUID)
    }

    let id: ID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let pinned: Bool
    let pinnedOrder: Int?
    let sessionOrder: Int?
    let folderID: UUID?
    let scheduledTaskID: String?

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        pinned = session.isPinned
        pinnedOrder = session.pinnedOrder
        sessionOrder = session.sessionOrder
        folderID = session.folderID
        scheduledTaskID = session.scheduledTaskID
    }

    init(imageGeneration session: ImageGenerationSessionSummary) {
        id = .imageGeneration(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        pinned = false
        pinnedOrder = nil
        sessionOrder = nil
        folderID = nil
        scheduledTaskID = nil
    }

    var chatID: UUID? {
        if case .chat(let sessionID) = id {
            return sessionID
        }
        return nil
    }

    var dragPayload: String? {
        chatID?.uuidString
    }

    var selection: ControlPanelSidebarSelection {
        switch id {
        case .chat(let sessionID):
            return .chat(sessionID)
        case .imageGeneration(let sessionID):
            return .imageGeneration(sessionID)
        }
    }

    var isChat: Bool {
        if case .chat = id {
            return true
        }
        return false
    }

    var badgeSystemImage: String? {
        switch id {
        case .chat:
            scheduledTaskID == nil ? nil : "clock"
        case .imageGeneration:
            "photo"
        }
    }

    var badgeLabel: String? {
        switch id {
        case .chat:
            scheduledTaskID == nil ? nil : "Scheduled task"
        case .imageGeneration:
            "Image session"
        }
    }

    static func recencySort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession)
        -> Bool
    {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    static func pinnedSort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession)
        -> Bool
    {
        switch (lhs.pinnedOrder, rhs.pinnedOrder) {
        case (let left?, let right?):
            return left == right ? recencySort(lhs, rhs) : left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return recencySort(lhs, rhs)
        }
    }

    static func sessionSort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession)
        -> Bool
    {
        switch (lhs.sessionOrder, rhs.sessionOrder) {
        case (let left?, let right?):
            return left == right ? recencySort(lhs, rhs) : left < right
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            return recencySort(lhs, rhs)
        }
    }
}
