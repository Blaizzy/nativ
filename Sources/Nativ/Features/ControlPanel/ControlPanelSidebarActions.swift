import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    func openChatSearchResult(_ result: ChatLibrarySearchResult) {
        guard chat.sessions.contains(where: { $0.id == result.sessionID }),
              result.isCurrent(in: chat.searchableTranscriptItems(in: result.sessionID)) else {
            chatLibrarySearch.refresh(from: chat, queryChanged: true)
            return
        }
        chat.selectSession(result.sessionID)
        guard chat.currentSessionID == result.sessionID else { return }
        applySidebarSelection(.chat(result.sessionID))
        chatLibrarySearch.select(result)
    }

    @ViewBuilder
    func recentSessionRow(
        _ recent: ControlPanelRecentSession,
        alignsContentWithSectionHeader: Bool = false
    ) -> some View {
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
            onTogglePin: {
                togglePinRecent(recent)
            },
            renameCommitRequests: sidebarRenameCommitRequests,
            alignsContentWithSectionHeader: alignsContentWithSectionHeader
        )
    }

    @ViewBuilder
    func projectSessionRow(
        _ recent: ControlPanelRecentSession,
        project: ChatProject
    ) -> some View {
        ControlPanelRecentSessionRow(
            recent: recent,
            isSelected: sidebarSelection == recent.selection,
            isCurrent: isCurrentRecent(recent),
            isSelectionDisabled: isRecentSelectionDisabled(recent),
            isDeleteDisabled: isRecentDeleteDisabled(recent),
            canExport: canExportRecent(recent),
            isSelecting: false,
            isChecked: false,
            onToggleSelect: {},
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
            onTogglePin: {},
            renameCommitRequests: sidebarRenameCommitRequests,
            allowsPinning: false,
            alignsContentWithSectionHeader: true
        )
        .padding(.leading, 8)
        .padding(.trailing, 8)
    }

    func togglePinRecent(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.setPinned(sessionID, pinned: !recent.pinned)
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
        return true
    }

    func enterSelectMode() {
        selectedRecentIDs = []
        isSelectingRecents = true
    }

    func exitSelectMode() {
        isSelectingRecents = false
        selectedRecentIDs = []
    }

    func toggleRecentSelection(_ recent: ControlPanelRecentSession) {
        if selectedRecentIDs.contains(recent.id) {
            selectedRecentIDs.remove(recent.id)
        } else {
            selectedRecentIDs.insert(recent.id)
        }
    }

    var selectedChats: [ControlPanelRecentSession] {
        recentSessions.filter { $0.isChat && selectedRecentIDs.contains($0.id) }
    }

    var bulkDeleteDescription: String {
        let base = "The selected chats and their managed worktrees and branches are permanently deleted. You’ll be asked before discarding uncommitted files or unmerged commits."
        let includesScheduledRun = selectedChats.contains { $0.scheduledTaskID != nil }
        guard includesScheduledRun else {
            return base
        }
        return "\(base) Linked scheduled tasks and their run records are kept."
    }

    var hasSelectedChats: Bool {
        !selectedChats.isEmpty
    }

    var allSelectedPinned: Bool {
        hasSelectedChats
            && selectedChats.allSatisfy(\.pinned)
    }

    var bulkSelectionTitle: String {
        let count = selectedRecentIDs.count
        return count == 0 ? "Select items" : "\(count) selected"
    }

    func bulkTogglePinSelected() {
        let shouldPin = !allSelectedPinned
        let chatIDs = selectedChats.compactMap(\.chatID)
        guard !chatIDs.isEmpty else {
            return
        }
        for id in chatIDs {
            chat.setPinned(id, pinned: shouldPin)
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

    func bulkDeleteSelected() async {
        let targets = recentSessions.filter { selectedRecentIDs.contains($0.id) }
        guard !targets.isEmpty else {
            return
        }
        let displayedIDs = Set(targets.filter { isDisplayedRecent($0) }.map(\.id))
        var removedIDs: Set<ControlPanelRecentSession.ID> = []
        for recent in targets {
            switch recent.selection {
            case .chat(let sessionID):
                guard await deleteChatSession(sessionID) else { continue }
            case .imageGeneration(let sessionID):
                imageGeneration.deleteSession(sessionID)
            case .tab, .extensionPage:
                continue
            }
            removedIDs.insert(recent.id)
        }
        withAnimation(.snappy(duration: 0.2)) {
            exitSelectMode()
        }
        guard !displayedIDs.isDisjoint(with: removedIDs) else {
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
