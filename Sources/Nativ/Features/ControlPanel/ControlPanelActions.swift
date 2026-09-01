import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    func createRecentSession() {
        if selectedTab == .chat, chatWorkspaceMode == .images {
            imageGeneration.beginNewDraft()
            showImageWorkspace()
        } else {
            createChatSession(projectID: activeProjectContextID)
        }
    }

    func handleNewChatRequest() {
        guard navigation.consumeNewChatRequest() else {
            return
        }
        createChatSession(projectID: activeProjectContextID)
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
            let archive = chat.archive(
                for: sessionID,
                selectedModelID: model.settings.normalized().languageModelID,
                systemPrompt: model.settings.systemPrompt
            )
        else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = chatExportFileName(for: recent.title)
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try ChatArchiveCodec.encode(archive).write(to: url, options: .atomic)
        } catch {
            chatImportAlert = .failed("The chat could not be exported: \(error.localizedDescription)")
        }
    }

    func importChat() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let archive = try ChatArchiveCodec.decode(Data(contentsOf: url))
            Task {
                await importChat(archive)
            }
        } catch {
            chatImportAlert = .failed(error.localizedDescription)
        }
    }

    func importChat(_ archive: ChatArchive) async {
        do {
            guard let sessionID = try chat.importArchive(archive) else {
                chatImportAlert = .failed("Nativ could not save the imported chat.")
                return
            }
            showChatWorkspace()
            applySidebarSelection(.chat(sessionID))
        } catch {
            chatImportAlert = .failed(error.localizedDescription)
            return
        }

        do {
            let models = try await LocalModelDiscovery.scan(
                searchPaths: model.settings.localModelSearchPaths
            )
            guard let originalModel = models.first(where: {
                $0.repoID == archive.modelRepositoryID
            }) else {
                chatImportAlert = .modelMissing(archive.modelRepositoryID)
                return
            }

            let selectedModelID = model.settings.normalized().languageModelID
            if selectedModelID != archive.modelRepositoryID {
                chatImportAlert = .switchModel(archive.modelRepositoryID)
            } else if let tokenCount = ChatArchiveCodec.promptTokenCount(in: archive),
                      let contextWindow = originalModel.contextSize,
                      tokenCount > contextWindow {
                chatImportAlert = .contextExceeded(
                    modelID: archive.modelRepositoryID,
                    tokenCount: tokenCount,
                    contextWindow: contextWindow
                )
            } else {
                chatImportAlert = .originalModel(archive.modelRepositoryID)
            }
        } catch {
            chatImportAlert = .failed(
                "The chat was imported, but Nativ could not check the local model library: "
                    + error.localizedDescription
            )
        }
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

    func chatExportFileName(for title: String) -> String {
        var name = sanitizedFileName(title)
        if name.lowercased().hasSuffix(".json") {
            name.removeLast(5)
        }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "Chat" : name).json"
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
        chat.deleteSession(sessionID)
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
            : activeProjectContextID.flatMap { projects.project(withID: $0)?.name }
                .map { "Create a new chat in \($0)" }
                ?? "Create a new chat"
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

    var activeProjectContextID: UUID? {
        selectedTab == .chat && chatWorkspaceMode == .chat
            ? chat.currentProjectID
            : nil
    }

    func createChatSession(projectID: UUID? = nil) {
        chat.createSession(projectID: projectID)
        showChatWorkspace()
    }

    func createProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Create Project"
        panel.message = "Choose a folder Nativ can read and write for this project."
        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return
        }

        do {
            let project = try projects.createProject(directoryURL: directoryURL)
            model.settings.sidebarProjectsCollapsed = false
            createChatSession(projectID: project.id)
        } catch {
            projectErrorMessage = error.localizedDescription
        }
    }

    func revealProject(_ project: ChatProject) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: project.rootPath, isDirectory: true)
        ])
    }

    func locateProject(_ project: ChatProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = projects.isRootAvailable(for: project) ? "Choose" : "Locate"
        panel.message = "Choose a readable and writable folder for “\(project.name)”."
        panel.directoryURL = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return
        }

        do {
            try projects.replaceRoot(for: project.id, with: directoryURL)
        } catch {
            projectErrorMessage = error.localizedDescription
        }
    }

    func removeProject(
        _ project: ChatProject,
        disposition: ChatProjectSessionRemovalDisposition
    ) {
        guard chat.removeProjectSessions(projectID: project.id, disposition: disposition) else {
            pendingDeleteProject = nil
            projectErrorMessage =
                "One or more project chats are active in another window. Stop them and try again."
            return
        }
        projects.removeProject(project.id)
        pendingDeleteProject = nil
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
        if chat.currentSessionID == nil {
            chat.createSession()
        }
        chatWorkspaceMode = .chat
        selectedTab = .chat
        sidebarSelection =
            chat.currentSessionID.map(ControlPanelSidebarSelection.chat)
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
