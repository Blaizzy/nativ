import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    @ViewBuilder
    func recentSessionRow(_ recent: ControlPanelRecentSession) -> some View {
        ControlPanelRecentSessionRow(
            recent: recent,
            isSelected: sidebarSelection == recent.selection,
            isCurrent: isCurrentRecent(recent),
            isSelectionDisabled: isRecentSelectionDisabled(recent),
            isDeleteDisabled: isRecentDeleteDisabled(recent),
            canExport: canExportRecent(recent),
            isSelecting: isSelectingRecents,
            isChecked: selectedRecentIDs.contains(recent.id),
            onToggleSelect: {
                toggleRecentSelection(recent)
            },
            onSelect: {
                applySidebarSelection(recent.selection)
            },
            onDelete: {
                pendingDeleteRecent = recent
            },
            onCopyConversation: {
                copyRecentConversation(recent)
            },
            onExportFile: {
                exportRecentConversation(recent)
            },
            onRevealInFinder: {
                revealRecentSession(recent)
            },
            onRename: { newTitle in
                renameRecentSession(recent, to: newTitle)
            },
            onNewChat: {
                createChatSession()
            },
            onTogglePin: {
                togglePinRecent(recent)
            },
            folders: sidebarState.recents.folders,
            onMoveToFolder: { folderID in
                moveRecentToFolder(recent, folderID: folderID)
            },
            onCreateFolderForSession: {
                createFolderForRecent(recent)
            }
        )
    }

    func togglePinRecent(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.setPinned(sessionID, pinned: !recent.pinned)
    }

    func moveRecentToFolder(_ recent: ControlPanelRecentSession, folderID: UUID?) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.moveSession(sessionID, toFolder: folderID)
    }

    func createFolderForRecent(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
              chat.canModifySession(sessionID)
        else {
            return
        }
        let folderID = chat.createFolder(name: "New Folder")
        chat.moveSession(sessionID, toFolder: folderID)
    }

    func draggedChatID(from items: [String]) -> UUID? {
        for item in items {
            if let id = UUID(uuidString: item),
                sidebarState.recents.containsChatSession(id)
            {
                return id
            }
        }
        return nil
    }

    func handlePinnedDrop(_ item: String) {
        if item.hasPrefix("folder:") {
            if let id = UUID(uuidString: String(item.dropFirst("folder:".count))) {
                chat.setFolderPinned(id, pinned: true)
            }
            return
        }
        _ = handlePinDrop([item])
    }

    func handlePinDrop(_ items: [String]) -> Bool {
        guard let draggedID = draggedChatID(from: items) else {
            return false
        }
        var order = pinnedSessions.compactMap(\.chatID)
        guard !order.contains(draggedID) else {
            return false
        }
        order.append(draggedID)
        reorderTargetID = nil
        reorderInsertAfter = false
        chat.applyPinnedOrder(order)
        return true
    }

    func handleSessionsDrop(_ items: [String]) -> Bool {
        guard let draggedID = draggedChatID(from: items) else {
            return false
        }
        reorderTargetID = nil
        reorderInsertAfter = false
        if pinnedSessions.contains(where: { $0.chatID == draggedID }) {
            chat.setPinned(draggedID, pinned: false)
        }
        chat.moveSession(draggedID, toFolder: nil)
        return true
    }

    func handleFolderReorder(dragged: UUID, target: UUID) {
        guard dragged != target else {
            return
        }
        var order = sidebarState.recents.folders.map(\.id)
        order.removeAll { $0 == dragged }
        if let index = order.firstIndex(of: target) {
            order.insert(dragged, at: index)
        } else {
            order.append(dragged)
        }
        chat.applyFolderOrder(order)
    }

    func enterSelectMode() {
        selectedRecentIDs = []
        selectedFolderIDs = []
        isSelectingRecents = true
    }

    func exitSelectMode() {
        isSelectingRecents = false
        selectedRecentIDs = []
        selectedFolderIDs = []
    }

    func toggleRecentSelection(_ recent: ControlPanelRecentSession) {
        if selectedRecentIDs.contains(recent.id) {
            selectedRecentIDs.remove(recent.id)
        } else {
            selectedRecentIDs.insert(recent.id)
        }
    }

    func toggleFolderSelection(_ folderID: UUID) {
        if selectedFolderIDs.contains(folderID) {
            selectedFolderIDs.remove(folderID)
        } else {
            selectedFolderIDs.insert(folderID)
        }
    }

    var selectedChats: [ControlPanelRecentSession] {
        recentSessions.filter { $0.isChat && selectedRecentIDs.contains($0.id) }
    }

    var bulkDeleteDescription: String {
        let base = "The selected chats are permanently deleted."
        let folders = "Selected folders are removed but their chats are kept."
        let includesScheduledRun = selectedChats.contains { $0.scheduledTaskID != nil }
        guard includesScheduledRun else {
            return "\(base) \(folders)"
        }
        return "\(base) Linked scheduled tasks and their run records are kept. \(folders)"
    }

    var hasSelectedChats: Bool {
        !selectedChats.isEmpty
    }

    var selectedFolders: [ChatFolder] {
        sidebarState.recents.folders.filter { selectedFolderIDs.contains($0.id) }
    }

    var hasSelectedPinnable: Bool {
        !selectedChats.isEmpty || !selectedFolders.isEmpty
    }

    var allSelectedPinned: Bool {
        hasSelectedPinnable
            && selectedChats.allSatisfy(\.pinned)
            && selectedFolders.allSatisfy(\.isPinned)
    }

    var bulkSelectionTitle: String {
        let count = selectedRecentIDs.count + selectedFolderIDs.count
        return count == 0 ? "Select items" : "\(count) selected"
    }

    func bulkTogglePinSelected() {
        let shouldPin = !allSelectedPinned
        let chatIDs = selectedChats.compactMap(\.chatID)
        let folderIDs = selectedFolders.map(\.id)
        guard !chatIDs.isEmpty || !folderIDs.isEmpty else {
            return
        }
        for id in chatIDs {
            chat.setPinned(id, pinned: shouldPin)
        }
        for id in folderIDs {
            chat.setFolderPinned(id, pinned: shouldPin)
        }
        exitSelectMode()
    }

    func bulkExportSelected() {
        let chats = selectedChats
        guard !chats.isEmpty else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }
        for recent in chats {
            guard case .chat(let sessionID) = recent.selection,
                let text = chat.conversationText(for: sessionID)
            else {
                continue
            }
            let url = uniqueExportURL(in: directory, title: recent.title)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        exitSelectMode()
    }

    func uniqueExportURL(in directory: URL, title: String) -> URL {
        let separators = CharacterSet(charactersIn: "/:")
        let sanitized = title.components(separatedBy: separators).joined(separator: "-")
        let base = sanitized.isEmpty ? "Chat" : sanitized
        var candidate = directory.appendingPathComponent("\(base).txt")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).txt")
            counter += 1
        }
        return candidate
    }

    func bulkDeleteSelected() {
        let targets = recentSessions.filter { selectedRecentIDs.contains($0.id) }
        let folderTargets = selectedFolderIDs
        guard !targets.isEmpty || !folderTargets.isEmpty else {
            return
        }
        let affectsDisplayed = targets.contains { isDisplayedRecent($0) }
        let removedIDs = selectedRecentIDs
        withAnimation(.snappy(duration: 0.2)) {
            for recent in targets {
                switch recent.selection {
                case .chat(let sessionID):
                    deleteChatSession(sessionID)
                case .imageGeneration(let sessionID):
                    imageGeneration.deleteSession(sessionID)
                case .tab, .extensionPage:
                    break
                }
            }
            for folderID in folderTargets {
                chat.deleteFolder(folderID)
            }
            exitSelectMode()
        }
        guard affectsDisplayed else {
            return
        }
        if let survivor = recentSessions.first(where: { !removedIDs.contains($0.id) }) {
            applySidebarSelection(survivor.selection)
        } else if chatWorkspaceMode == .images {
            imageGeneration.beginNewDraft()
            showImageWorkspace()
        } else {
            createChatSession()
        }
    }

    func renameRecentSession(_ recent: ControlPanelRecentSession, to newTitle: String) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.renameSession(sessionID, to: newTitle)
    }

}
