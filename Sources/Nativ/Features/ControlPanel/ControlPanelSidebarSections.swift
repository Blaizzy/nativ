import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarPinnedHeader
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.bottom, 4)

            if !chromeState.sidebarPinnedCollapsed {
                Group {
                    if pinnedSessions.isEmpty && pinnedFolders.isEmpty {
                        emptyPinnedHint
                    } else {
                        ForEach(pinnedFolders) { folder in
                            folderView(folder, dropTargeted: isPinnedDropTargeted)
                        }
                        ForEach(pinnedSessions) { recent in
                            draggableRow(recent, isPinnedRow: true)
                                .overlay(alignment: .top) {
                                    pinnedInsertionLine(
                                        visible: reorderTargetID == recent.id && !reorderInsertAfter
                                            && isPinnedDropTargeted)
                                }
                                .overlay(alignment: .bottom) {
                                    pinnedInsertionLine(
                                        visible: reorderTargetID == recent.id && reorderInsertAfter
                                            && isPinnedDropTargeted)
                                }
                        }
                    }
                }
                .transition(.slide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight(isTargeted: isPinnedDropTargeted))
        .onDrop(of: [.text], isTargeted: $isPinnedDropTargeted) { providers in
            loadDropString(providers) { payload in
                revealSidebarSection(\.sidebarPinnedCollapsed)
                handlePinnedDrop(payload)
            }
        }
    }

    var showsPinnedSection: Bool {
        isSelectingRecents || !pinnedSessions.isEmpty || !pinnedFolders.isEmpty
    }

    var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarRecentsHeader
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.top, showsPinnedSection || showsFoldersSection ? 12 : 0)
                .padding(.bottom, 4)

            if !chromeState.sidebarSessionsCollapsed {
                ForEach(ungroupedSessions) { recent in
                    draggableRow(recent, isPinnedRow: false)
                        .overlay(alignment: .top) {
                            pinnedInsertionLine(
                                visible: reorderTargetID == recent.id && !reorderInsertAfter
                                    && isSessionsDropTargeted)
                        }
                        .overlay(alignment: .bottom) {
                            pinnedInsertionLine(
                                visible: reorderTargetID == recent.id && reorderInsertAfter
                                    && isSessionsDropTargeted)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight(isTargeted: isSessionsDropTargeted))
        .onDrop(of: [.text], isTargeted: $isSessionsDropTargeted) { providers in
            loadDropString(providers) { payload in
                revealSidebarSection(\.sidebarSessionsCollapsed)
                _ = handleSessionsDrop([payload])
            }
        }
    }

    var foldersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarFoldersHeader
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if !chromeState.sidebarFoldersCollapsed {
                if unpinnedFolders.isEmpty {
                    emptyFoldersHint
                } else {
                    ForEach(unpinnedFolders) { folder in
                        folderView(folder, dropTargeted: isFoldersDropTargeted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight(isTargeted: isFoldersDropTargeted))
        .onDrop(of: [.text], isTargeted: $isFoldersDropTargeted) { _ in false }
    }

    var showsFoldersSection: Bool {
        isSelectingRecents || !unpinnedFolders.isEmpty
    }

    var emptyFoldersHint: some View {
        Label("No folders yet — tap + to add one", systemImage: "folder")
            .font(.system(size: 13))
            .foregroundStyle(.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    func folderView(_ folder: ChatFolder, dropTargeted: Bool) -> some View {
        ControlPanelFolderHeaderView(
            folder: folder,
            count: sessions(inFolder: folder.id).count,
            isSelecting: isSelectingRecents,
            isChecked: selectedFolderIDs.contains(folder.id),
            onToggleCollapse: {
                chat.setFolderCollapsed(folder.id, collapsed: !folder.isCollapsed)
            },
            onRename: { chat.renameFolder(folder.id, to: $0) },
            onTogglePin: {
                chat.setFolderPinned(folder.id, pinned: !folder.isPinned)
            },
            onToggleSelect: {
                toggleFolderSelection(folder.id)
            },
            onExport: {
                exportFolder(folder)
            },
            onDelete: {
                pendingDeleteFolder = folder
            }
        )
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .onDrag {
            NSItemProvider(object: "folder:\(folder.id.uuidString)" as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: FolderDropDelegate(
                onChatDrop: { chatID in
                    chat.moveSession(chatID, toFolder: folder.id)
                },
                onFolderDrop: { draggedFolderID in
                    handleFolderReorder(dragged: draggedFolderID, target: folder.id)
                }
            ))

        if !folder.isCollapsed {
            ForEach(sessions(inFolder: folder.id)) { recent in
                folderChatRow(recent, folderID: folder.id)
                    .overlay(alignment: .top) {
                        pinnedInsertionLine(
                            visible: reorderTargetID == recent.id && !reorderInsertAfter
                                && dropTargeted)
                    }
                    .overlay(alignment: .bottom) {
                        pinnedInsertionLine(
                            visible: reorderTargetID == recent.id && reorderInsertAfter
                                && dropTargeted)
                    }
                    .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    func folderChatRow(_ recent: ControlPanelRecentSession, folderID: UUID) -> some View {
        if let payload = recent.dragPayload, !isSelectingRecents {
            recentSessionRow(recent)
                .onDrag {
                    NSItemProvider(object: payload as NSString)
                } preview: {
                    dragPreview(recent)
                }
                .onDrop(
                    of: [.text],
                    delegate: RowReorderDropDelegate(
                        targetID: recent.id,
                        setTarget: { id, after in
                            if reorderTargetID != id || reorderInsertAfter != after {
                                reorderTargetID = id
                                reorderInsertAfter = after
                            }
                        },
                        onDrop: { draggedPayload, after in
                            handleFolderRowDrop(
                                draggedPayload: draggedPayload,
                                target: recent,
                                insertAfter: after,
                                folderID: folderID
                            )
                        }
                    ))
        } else {
            recentSessionRow(recent)
        }
    }

    var emptyPinnedHint: some View {
        Label("Drag a chat here to pin", systemImage: "pin")
            .font(.system(size: 13))
            .foregroundStyle(.secondary.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .contentShape(.rect)
    }

    func sidebarSectionHeader<Trailing: View>(
        title: String,
        isCollapsed: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.7))

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .frame(width: 12)

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    onToggle()
                }
            }
            .help(isCollapsed ? "Expand \(title)" : "Collapse \(title)")

            trailing()
        }
    }

    var sidebarPinnedHeader: some View {
        sidebarSectionHeader(
            title: "Pinned",
            isCollapsed: chromeState.sidebarPinnedCollapsed,
            onToggle: { model.settings.sidebarPinnedCollapsed.toggle() },
            trailing: { EmptyView() }
        )
    }

    var sidebarFoldersHeader: some View {
        sidebarSectionHeader(
            title: "Folders",
            isCollapsed: chromeState.sidebarFoldersCollapsed,
            onToggle: { model.settings.sidebarFoldersCollapsed.toggle() },
            trailing: {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        model.settings.sidebarFoldersCollapsed = false
                        _ = chat.createFolder(name: "New Folder")
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("New folder")
            }
        )
    }

    var sidebarRecentsHeader: some View {
        sidebarSectionHeader(
            title: "Sessions",
            isCollapsed: chromeState.sidebarSessionsCollapsed,
            onToggle: { model.settings.sidebarSessionsCollapsed.toggle() },
            trailing: { EmptyView() }
        )
    }

    var allSidebarSectionsCollapsed: Bool {
        chromeState.sidebarPinnedCollapsed
            && chromeState.sidebarFoldersCollapsed
            && chromeState.sidebarSessionsCollapsed
            && !sidebarState.recents.folders.contains { !$0.isCollapsed }
    }

    func revealSidebarSection(_ keyPath: WritableKeyPath<NativSettings, Bool>) {
        guard model.settings[keyPath: keyPath] else {
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            model.settings[keyPath: keyPath] = false
        }
    }

    func toggleAllSidebarSections() {
        let shouldCollapse = !allSidebarSectionsCollapsed
        withAnimation(.snappy(duration: 0.2)) {
            model.settings.setAllSidebarSectionsCollapsed(shouldCollapse)
            chat.setAllFoldersCollapsed(shouldCollapse)
        }
    }

    func toggleSidebarVisibility() {
        let willShowSidebar = !isSidebarVisuallyVisible
        sidebarTransitionGeneration &+= 1
        let transitionGeneration = sidebarTransitionGeneration
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSidebarTransitioning = true
            splitColumnVisibility = willShowSidebar ? .all : .detailOnly
            detailTransitionOffset = willShowSidebar ? -sidebarWidth : sidebarWidth
        }
        withAnimation(.smooth(duration: ControlPanelLayout.sidebarTransitionDuration)) {
            isSidebarVisuallyVisible = willShowSidebar
            detailTransitionOffset = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: ControlPanelLayout.sidebarTransitionSettleDuration)
            guard sidebarTransitionGeneration == transitionGeneration else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isSidebarTransitioning = false
            }
        }
    }

    func toggleModelConfigurationVisibility() {
        isModelConfigurationVisible.toggle()
    }

    var showsModelConfigurationToggle: Bool {
        switch selectedTab {
        case .chat:
            chatWorkspaceMode == .chat
        case .models:
            true
        case .dev:
            selectedDevSection == .developer
        case .scheduled, .artifacts, .dashboard, .system, .extensions, .settings:
            false
        }
    }

    var recentSessions: [ControlPanelRecentSession] {
        sidebarState.recents.recentSessions.filter(shouldDisplayRecentSession)
    }

    var scheduledTaskChatIDs: Set<UUID> {
        Set(routineStore.routines.compactMap(\.sourceSessionID))
    }

    var scheduledRunChatIDs: Set<UUID> {
        Set(routineStore.runs.compactMap(\.sessionID))
    }

    func shouldDisplayRecentSession(_ recent: ControlPanelRecentSession) -> Bool {
        guard case .chat(let sessionID) = recent.selection else {
            return true
        }
        if scheduledTaskChatIDs.contains(sessionID) {
            return true
        }
        return recent.scheduledTaskID == nil && !scheduledRunChatIDs.contains(sessionID)
    }

    var pinnedSessions: [ControlPanelRecentSession] {
        sidebarState.recents.pinnedSessions
    }

    var unpinnedSessions: [ControlPanelRecentSession] {
        sidebarState.recents.unpinnedSessions
    }

    var ungroupedSessions: [ControlPanelRecentSession] {
        sidebarState.recents.ungroupedSessions
    }

    var pinnedFolders: [ChatFolder] {
        sidebarState.recents.pinnedFolders
    }

    var unpinnedFolders: [ChatFolder] {
        sidebarState.recents.unpinnedFolders
    }

    func sessions(inFolder folderID: UUID) -> [ControlPanelRecentSession] {
        sidebarState.recents.sessions(inFolder: folderID)
    }

}
