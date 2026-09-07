import AppKit
import Combine
import NativExtensionSDK
import NativServerKit
import SwiftUI
import UniformTypeIdentifiers

struct RowReorderDropDelegate: DropDelegate {
    let targetID: ControlPanelRecentSession.ID
    let setTarget: (ControlPanelRecentSession.ID?, Bool) -> Void
    let onDrop: (String, Bool) -> Void
    private let rowHeight: CGFloat = 30

    func dropEntered(info: DropInfo) {
        setTarget(targetID, info.location.y > rowHeight / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setTarget(targetID, info.location.y > rowHeight / 2)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setTarget(nil, false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertAfter = info.location.y > rowHeight / 2
        setTarget(nil, false)
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, !string.isEmpty {
                DispatchQueue.main.async {
                    onDrop(string, insertAfter)
                }
            }
        }
        return true
    }
}

struct FolderDropDelegate: DropDelegate {
    let onChatDrop: (UUID) -> Void
    let onFolderDrop: (UUID) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, !string.isEmpty else {
                return
            }
            DispatchQueue.main.async {
                if string.hasPrefix("folder:") {
                    if let id = UUID(uuidString: String(string.dropFirst("folder:".count))) {
                        onFolderDrop(id)
                    }
                } else if let id = UUID(uuidString: string) {
                    onChatDrop(id)
                }
            }
        }
        return true
    }
}

extension ControlPanelView {
    func dropHighlight(isTargeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(isTargeted ? 0.08 : 0))
    }

    @ViewBuilder
    func draggableRow(
        _ recent: ControlPanelRecentSession,
        isPinnedRow: Bool
    ) -> some View {
        if let payload = recent.dragPayload, !isSelectingRecents {
            recentSessionRow(recent, alignsContentWithSectionHeader: true)
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
                            handleRowDrop(
                                draggedPayload: draggedPayload,
                                target: recent,
                                insertAfter: after,
                                isPinnedRow: isPinnedRow
                            )
                        }
                    ))
        } else {
            recentSessionRow(recent, alignsContentWithSectionHeader: true)
        }
    }

    func handleRowDrop(
        draggedPayload: String,
        target: ControlPanelRecentSession,
        insertAfter: Bool,
        isPinnedRow: Bool
    ) {
        guard let draggedID = UUID(uuidString: draggedPayload),
            sidebarState.recents.containsChatSession(draggedID),
            let targetID = target.chatID,
            draggedID != targetID
        else {
            return
        }
        var order = (isPinnedRow ? pinnedSessions : unpinnedSessions).compactMap(\.chatID)
        order.removeAll { $0 == draggedID }
        if let index = order.firstIndex(of: targetID) {
            order.insert(draggedID, at: insertAfter ? index + 1 : index)
        } else {
            order.append(draggedID)
        }
        reorderTargetID = nil
        reorderInsertAfter = false
        if isPinnedRow {
            chat.applyPinnedOrder(order)
        } else {
            chat.applySessionOrder(order)
        }
    }

    func handleFolderRowDrop(
        draggedPayload: String,
        target: ControlPanelRecentSession,
        insertAfter: Bool,
        folderID: UUID
    ) {
        reorderTargetID = nil
        reorderInsertAfter = false
        guard let draggedID = UUID(uuidString: draggedPayload),
            sidebarState.recents.containsChatSession(draggedID),
            let targetID = target.chatID,
            draggedID != targetID
        else {
            return
        }
        var order = sessions(inFolder: folderID).compactMap(\.chatID)
        order.removeAll { $0 == draggedID }
        if let index = order.firstIndex(of: targetID) {
            order.insert(draggedID, at: insertAfter ? index + 1 : index)
        } else {
            order.append(draggedID)
        }
        chat.moveSession(draggedID, toFolder: folderID)
        chat.applySessionOrder(order)
    }

    @discardableResult
    func loadDropString(
        _ providers: [NSItemProvider],
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) -> Bool {
        guard let provider = providers.first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, !string.isEmpty {
                DispatchQueue.main.async { handler(string) }
            }
        }
        return true
    }

    func pinnedInsertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .opacity(visible ? 1 : 0)
    }

    func dragPreview(_ recent: ControlPanelRecentSession) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
            Text(recent.title)
                .nativTextStyle(.rowTitle)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

}
