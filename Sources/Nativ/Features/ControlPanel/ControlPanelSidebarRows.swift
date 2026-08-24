import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelRecentSessionRow: View {
    let recent: ControlPanelRecentSession
    let isSelected: Bool
    let isCurrent: Bool
    let isSelectionDisabled: Bool
    let isDeleteDisabled: Bool
    let canExport: Bool
    let isSelecting: Bool
    let isChecked: Bool
    let onToggleSelect: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onCopyConversation: () -> Void
    let onExportFile: () -> Void
    let onRevealInFinder: () -> Void
    let onRename: (String) -> Void
    let onNewChat: () -> Void
    let onTogglePin: () -> Void
    let folders: [ChatFolder]
    let onMoveToFolder: (UUID?) -> Void
    let onCreateFolderForSession: () -> Void
    @State private var isHovering = false
    @State private var isDeleteHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if isRenaming {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    TextField("Name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .focused($renameFieldFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            isRenaming = false
                        }
                        // Clicking away ends the rename (commit) instead of
                        // leaving a stuck field/caret that swallows clicks.
                        .onChange(of: renameFieldFocused) { _, focused in
                            if !focused, isRenaming { commitRename() }
                        }
                }
                .padding(.trailing, isHovering && !isSelecting ? 52 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sidebarRowSelectionStyle(isSelected: isSelecting ? isChecked : isSelected)
            } else {
                Button {
                    activateRow()
                } label: {
                    HStack(spacing: 7) {
                        if isSelecting {
                            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                                .accessibilityLabel(isChecked ? "Selected" : "Not selected")
                        } else {
                            Circle()
                                .fill(isCurrent ? Color.accentColor : Color.clear)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }

                        if let badgeSystemImage = recent.badgeSystemImage {
                            Image(systemName: badgeSystemImage)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.secondary.opacity(0.1))
                                )
                                .help(recent.badgeLabel ?? "Session")
                                .accessibilityLabel(recent.badgeLabel ?? "Session")
                        }

                        Text(recent.title)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, isHovering && !isSelecting ? 52 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .sidebarRowSelectionStyle(isSelected: isSelecting ? isChecked : isSelected)
                }
                .buttonStyle(.plain)
                .disabled(isSelectionDisabled && !isSelecting)
                .help(recent.title)
            }

            HStack(spacing: 2) {
                Menu {
                    rowMenuContents
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .frame(width: 24, height: 20)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Actions")
                .opacity(isHovering && !isSelecting ? 1 : 0)
                .allowsHitTesting(isHovering && !isSelecting)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isDeleteHovering ? Color.red.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
                .disabled(isDeleteDisabled)
                .help("Delete \(recent.title)")
                .opacity(isHovering && !isSelecting && !isDeleteDisabled ? 1 : 0)
                .allowsHitTesting(isHovering && !isSelecting && !isDeleteDisabled)
                .onHover { isDeleteHovering = $0 }
            }
            .padding(.trailing, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .opacity(isSelectionDisabled && !isCurrent && !isSelecting ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .contextMenu {
            rowMenuContents
        }
    }

    private func activateRow() {
        if isSelecting {
            onToggleSelect()
        } else if isSelected, recent.isChat {
            beginRename()
        } else {
            onSelect()
        }
    }

    @ViewBuilder
    private var rowMenuContents: some View {
        Button {
            onNewChat()
        } label: {
            Label("New", systemImage: "square.and.pencil")
        }

        if recent.isChat {
            Divider()

            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                onTogglePin()
            } label: {
                Label(
                    recent.pinned ? "Unpin" : "Pin",
                    systemImage: recent.pinned ? "pin.slash" : "pin"
                )
            }

            Menu {
                if recent.folderID != nil {
                    Button {
                        onMoveToFolder(nil)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                    Divider()
                }
                ForEach(folders) { folder in
                    Button {
                        onMoveToFolder(folder.id)
                    } label: {
                        if folder.id == recent.folderID {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
                if !folders.isEmpty {
                    Divider()
                }
                Button {
                    onCreateFolderForSession()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
        }

        Divider()

        if canExport {
            Button {
                onExportFile()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(isDeleteDisabled)
    }

    private func beginRename() {
        renameDraft = recent.title
        isRenaming = true
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        isRenaming = false
        onRename(renameDraft)
    }
}

struct ControlPanelFolderHeaderView: View {
    let folder: ChatFolder
    let count: Int
    let isSelecting: Bool
    let isChecked: Bool
    let onToggleCollapse: () -> Void
    let onRename: (String) -> Void
    let onTogglePin: () -> Void
    let onToggleSelect: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .frame(width: 12)
            } else {
                Button(action: onToggleCollapse) {
                    Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit {
                        commitRename()
                    }
                    .onExitCommand {
                        isRenaming = false
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused, isRenaming { commitRename() }
                    }
            } else {
                Text(folder.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if !isSelecting {
                beginRename()
            }
        }
        .onTapGesture {
            if isSelecting {
                onToggleSelect()
            }
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                onTogglePin()
            } label: {
                Label(
                    folder.isPinned ? "Unpin" : "Pin",
                    systemImage: folder.isPinned ? "pin.slash" : "pin"
                )
            }

            Button {
                onExport()
            } label: {
                Label("Export Folder", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    private func beginRename() {
        renameDraft = folder.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        isRenaming = false
        onRename(renameDraft)
    }
}

struct SidebarRowSelectionStyle: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(Color.primary)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
    }
}

extension View {
    func sidebarRowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarRowSelectionStyle(isSelected: isSelected))
    }
}
