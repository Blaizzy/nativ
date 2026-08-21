import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    var detailTitleLeadingInset: CGFloat {
        splitColumnVisibility == .detailOnly
            ? ControlPanelLayout.collapsedSidebarTitleClearance
            : 0
    }

    var detailExtendsIntoTitlebar: Bool {
        if case .extensionPage = sidebarSelection {
            return true
        }
        switch selectedTab {
        case .scheduled, .dashboard, .system, .models, .extensions, .dev:
            return true
        case .chat, .artifacts, .settings:
            return false
        }
    }

    func createRecentSession() {
        if selectedTab == .chat, chatWorkspaceMode == .images {
            imageGeneration.beginNewDraft()
            showImageWorkspace()
        } else {
            createChatSession()
        }
    }

    func handleNewChatRequest() {
        guard navigation.consumeNewChatRequest() else {
            return
        }
        createChatSession()
    }

    func handleToggleSidebarRequest() {
        guard navigation.consumeToggleSidebarRequest() else {
            return
        }
        toggleSidebarVisibility()
    }

    func handleCollapseAllSectionsRequest() {
        guard navigation.consumeCollapseAllSectionsRequest() else {
            return
        }
        toggleAllSidebarSections()
    }

    func canExportRecent(_ recent: ControlPanelRecentSession) -> Bool {
        if case .chat = recent.selection {
            return true
        }
        return false
    }

    func copyRecentConversation(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
            let text = chat.conversationText(for: sessionID)
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportRecentConversation(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
            let text = chat.conversationText(for: sessionID)
        else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recent.title).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportFolder(_ folder: ChatFolder) {
        let chatIDs = sessions(inFolder: folder.id).compactMap(\.chatID)
        guard !chatIDs.isEmpty else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }
        let root = directory.appendingPathComponent(
            sanitizedFileName(folder.name), isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var usedNames: Set<String> = []
        for sessionID in chatIDs {
            guard let text = chat.conversationText(for: sessionID) else {
                continue
            }
            let title = sidebarState.recents.chatTitle(for: sessionID) ?? sessionID.uuidString
            let base = sanitizedFileName(title)
            var candidate = base
            var suffix = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }
            usedNames.insert(candidate.lowercased())
            let fileURL = root.appendingPathComponent("\(candidate).txt")
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    func revealRecentSession(_ recent: ControlPanelRecentSession) {
        let fileURL: URL?
        switch recent.selection {
        case .chat(let sessionID):
            fileURL = chat.sessionDataFileURL(for: sessionID)
        case .imageGeneration(let sessionID):
            fileURL = imageGeneration.sessionDataFileURL(for: sessionID)
        case .tab, .extensionPage:
            fileURL = nil
        }
        guard let fileURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func deleteRecentSession(_ recent: ControlPanelRecentSession) {
        let shouldSelectReplacement = isDisplayedRecent(recent)
        let replacementSelection =
            shouldSelectReplacement
            ? adjacentRecentSelection(to: recent)
            : nil

        switch recent.selection {
        case .chat(let sessionID):
            deleteChatSession(sessionID)
        case .imageGeneration(let sessionID):
            imageGeneration.deleteSession(sessionID)
        case .tab, .extensionPage:
            break
        }

        guard shouldSelectReplacement else {
            return
        }
        if let replacementSelection {
            applySidebarSelection(replacementSelection)
        } else {
            switch recent.selection {
            case .imageGeneration:
                imageGeneration.beginNewDraft()
                showImageWorkspace()
            case .chat, .tab, .extensionPage:
                createChatSession()
            }
        }
    }

    func deleteChatSession(_ sessionID: UUID) {
        guard let routine = routineStore.routine(forSession: sessionID) else {
            chat.deleteSession(sessionID)
            return
        }

        let sessionIDs = Set(
            [routine.sourceSessionID].compactMap { $0 }
                + routineStore.runs(forRoutine: routine.id).compactMap(\.sessionID)
        )
        routineStore.delete(id: routine.id)
        for linkedSessionID in sessionIDs {
            chat.deleteSession(linkedSessionID)
        }
    }

    func adjacentRecentSelection(
        to recent: ControlPanelRecentSession
    ) -> ControlPanelSidebarSelection? {
        let recents = recentSessions
        guard let index = recents.firstIndex(where: { $0.id == recent.id }) else {
            return nil
        }
        let nextIndex = recents.index(after: index)
        if recents.indices.contains(nextIndex) {
            return recents[nextIndex].selection
        }
        guard index > recents.startIndex else {
            return nil
        }
        return recents[recents.index(before: index)].selection
    }

    func isDisplayedRecent(_ recent: ControlPanelRecentSession) -> Bool {
        if sidebarSelection == recent.selection {
            return true
        }
        switch (sidebarSelection, recent.selection) {
        case (.tab(.chat), .chat(let sessionID)):
            return chatWorkspaceMode == .chat && sessionID == sidebarState.currentChatSessionID
        case (.tab(.chat), .imageGeneration(let sessionID)):
            return chatWorkspaceMode == .images
                && sessionID == sidebarState.currentImageSessionID
        default:
            return false
        }
    }

    func isCurrentRecent(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == sidebarState.currentChatSessionID
        case .imageGeneration(let sessionID):
            return sessionID == sidebarState.currentImageSessionID
        case .tab, .extensionPage:
            return false
        }
    }

    func isRecentDeleteDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            // Deleting a chat now cancels its in-flight request first, so a busy
            // session is safe to remove. Disabling this button left a chat whose
            // stream never finished permanently undeletable.
            return false
        case .imageGeneration:
            return sidebarState.isGeneratingImage
        case .tab, .extensionPage:
            return false
        }
    }

    func isRecentSelectionDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return false
        case .imageGeneration:
            return sidebarState.isGeneratingImage
        case .tab, .extensionPage:
            return false
        }
    }

    var newRecentHelp: String {
        selectedTab == .chat && chatWorkspaceMode == .images
            ? "Start a new image draft"
            : "Create a new chat"
    }

    var newRecentTitle: String {
        selectedTab == .chat && chatWorkspaceMode == .images
            ? "New image"
            : "New chat"
    }

    var newRecentSystemImage: String {
        selectedTab == .chat && chatWorkspaceMode == .images
            ? "photo.badge.plus"
            : "square.and.pencil"
    }

    func createChatSession() {
        chat.createSession()
        showChatWorkspace()
    }

    func selectChatWorkspaceMode(_ mode: ChatWorkspaceMode) {
        guard mode != chatWorkspaceMode else {
            return
        }
        switch mode {
        case .chat:
            showChatWorkspace()
        case .images:
            imageGeneration.beginNewDraft(preservingUncommittedDraft: true)
            showImageWorkspace()
        }
    }

    func showChatWorkspace() {
        if sidebarState.currentChatSessionID == nil {
            chat.createSession()
        }
        chatWorkspaceMode = .chat
        selectedTab = .chat
        sidebarSelection =
            sidebarState.currentChatSessionID.map(ControlPanelSidebarSelection.chat)
            ?? .tab(.chat)
    }

    func showImageWorkspace() {
        chatWorkspaceMode = .images
        selectedTab = .chat
        sidebarSelection =
            sidebarState.currentImageSessionID
            .map(ControlPanelSidebarSelection.imageGeneration)
            ?? .tab(.chat)
    }

}
