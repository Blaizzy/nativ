import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

extension ControlPanelView {
    var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(
                    height: isFullScreen
                        ? ControlPanelLayout.fullScreenTopClearance
                        : 0
                )

            HStack(spacing: 6) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: ControlPanelLayout.sidebarBrandIconSize,
                        height: ControlPanelLayout.sidebarBrandIconSize
                    )

                Text("Nativ")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ControlPanelLayout.sidebarBrandHeight)
            .padding(.horizontal, 16)
            .padding(.bottom, ControlPanelLayout.sidebarBrandBottomClearance)

            sidebarNavigation
                .padding(.horizontal, 10)
                .padding(.bottom, 5)

            if isSelectingRecents {
                bulkSelectionBar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            } else {
                sidebarActionBar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsPinnedSection {
                        pinnedSection
                    }
                    if showsFoldersSection {
                        foldersSection
                    }
                    sessionsSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: sidebarSeparatorThickness)

            HStack(spacing: 4) {
                settingsButton
                supportButton
                serverToggleButton
                issueReportMenu
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .navigationTitle("Nativ")
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { pendingDeleteRecent != nil },
                set: { if !$0 { pendingDeleteRecent = nil } }
            ),
            presenting: pendingDeleteRecent
        ) { recent in
            Button("Delete", role: .destructive) {
                deleteRecentSession(recent)
                pendingDeleteRecent = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteRecent = nil
            }
        } message: { recent in
            if case .chat(let sessionID) = recent.selection,
                contentState.routine(forSession: sessionID) != nil
            {
                Text(
                    "“\(recent.title)” is a scheduled task. Deleting this chat also deletes "
                        + "the scheduled task and its run history."
                )
            } else {
                Text("“\(recent.title)” will be permanently deleted.")
            }
        }
        .alert(
            "Delete folder?",
            isPresented: Binding(
                get: { pendingDeleteFolder != nil },
                set: { if !$0 { pendingDeleteFolder = nil } }
            ),
            presenting: pendingDeleteFolder
        ) { folder in
            Button("Delete", role: .destructive) {
                chat.deleteFolder(folder.id)
                pendingDeleteFolder = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDeleteFolder = nil
            }
        } message: { folder in
            Text("“\(folder.name)” will be removed. Its chats will be moved out, not deleted.")
        }
        .alert(
            "Delete \(selectedRecentIDs.count + selectedFolderIDs.count) items?",
            isPresented: $isConfirmingBulkDelete
        ) {
            Button("Delete", role: .destructive) {
                bulkDeleteSelected()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(bulkDeleteDescription)
        }
    }

    var resizableSidebar: some View {
        sidebar
            .frame(width: sidebarWidth)
            .background {
                ControlPanelSidebarMaterial()
                    .overlay {
                        Color.white.opacity(0.1)
                            .allowsHitTesting(false)
                    }
                    .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
            }
            .overlay(alignment: .trailing) {
                sidebarResizeHandle
            }
            .zIndex(1)
    }

    var sidebarResizeHandle: some View {
        ZStack {
            Color.clear

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: sidebarSeparatorThickness)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .offset(x: 4)
        .onHover { isHovering in
            (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if sidebarDragStartWidth == nil {
                        sidebarDragStartWidth = sidebarWidth
                    }

                    let startWidth = sidebarDragStartWidth ?? sidebarWidth
                    let proposedWidth = startWidth + value.translation.width
                    sidebarWidth = min(
                        max(proposedWidth, ControlPanelLayout.sidebarMinimumWidth),
                        ControlPanelLayout.sidebarMaximumWidth
                    )
                }
                .onEnded { _ in
                    sidebarDragStartWidth = nil
                    NSCursor.arrow.set()
                }
        )
    }

    var sidebarSeparatorThickness: CGFloat {
        1 / max(displayScale, 1)
    }

    var sidebarNavigation: some View {
        VStack(spacing: 0) {
            ForEach(ControlPanelTab.allCases) { tab in
                sidebarTabButton(tab)

                if tab == .chat {
                    ForEach(contentState.extensionSidebarContributions) { contribution in
                        extensionSidebarButton(contribution)
                    }
                }
            }
        }
    }

    func sidebarTabButton(_ tab: ControlPanelTab) -> some View {
        let selection = ControlPanelSidebarSelection.tab(tab)
        return Button {
            applySidebarSelection(selection)
        } label: {
            HStack(spacing: 8) {
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .labelStyle(SidebarNavigationLabelStyle())
                if tab == .extensions, !isExtensionsBadgeDismissed {
                    Text("NEW")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer(minLength: 0)
                if tab == .models {
                    HStack(spacing: 6) {
                        if chromeState.isModelLoading,
                            let percentage = chromeState.modelLoadingPercentageText
                        {
                            Text(percentage)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                        ModelsDownloadBadge(downloads: downloads)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }

    func extensionSidebarButton(
        _ contribution: NativSidebarContribution
    ) -> some View {
        let selection = ControlPanelSidebarSelection.extensionPage(contribution.id)
        return Button {
            applySidebarSelection(selection)
        } label: {
            Label(contribution.title, systemImage: contribution.systemImage)
                .labelStyle(SidebarNavigationLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }

}
