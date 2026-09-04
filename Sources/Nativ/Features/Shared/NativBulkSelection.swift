import SwiftUI

/// Selection state shared by component-scoped bulk-management flows.
struct NativBulkSelection<ID: Hashable> {
    private(set) var isActive = false
    private(set) var ids = Set<ID>()

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: ID) -> Bool {
        ids.contains(id)
    }

    func includesAll(_ candidateIDs: Set<ID>) -> Bool {
        !candidateIDs.isEmpty && ids.isSuperset(of: candidateIDs)
    }

    mutating func toggleMode() {
        isActive.toggle()
        if !isActive {
            ids.removeAll()
        }
    }

    mutating func toggle(_ id: ID) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    mutating func toggleAll(_ candidateIDs: Set<ID>) {
        guard !candidateIDs.isEmpty else { return }
        if includesAll(candidateIDs) {
            ids.subtract(candidateIDs)
        } else {
            ids.formUnion(candidateIDs)
        }
    }

    mutating func selectAll(_ candidateIDs: Set<ID>) {
        isActive = true
        ids = candidateIDs
    }

    mutating func retain(_ candidateIDs: Set<ID>) {
        ids.formIntersection(candidateIDs)
    }

    mutating func remove<S: Sequence>(_ removedIDs: S) where S.Element == ID {
        ids.subtract(removedIDs)
    }

    mutating func finish() {
        isActive = false
        ids.removeAll()
    }
}

/// The shared selection affordance for bulk-management lists.
struct NativBulkSelectionCheckbox: View {
    let isSelected: Bool
    var isEnabled = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.55),
                            lineWidth: 1.25
                        )
                }

            if isSelected {
                Image(systemName: "checkmark")
                    .nativTextStyle(.badgeStrong)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .accessibilityHidden(true)
    }
}

private struct NativBulkSelectionSurface: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if isSelecting {
                Button(action: action) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                            }
                        }
                        .contentShape(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
        }
    }
}

extension View {
    /// Makes an entire row or card the selection control while bulk selection is active.
    func nativBulkSelectable(
        isSelecting: Bool,
        isSelected: Bool,
        isEnabled: Bool = true,
        cornerRadius: CGFloat = 12,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            NativBulkSelectionSurface(
                isSelecting: isSelecting,
                isSelected: isSelected,
                isEnabled: isEnabled,
                cornerRadius: cornerRadius,
                accessibilityLabel: accessibilityLabel,
                action: action
            )
        )
    }
}

/// Shared controls for selecting every visible item and performing bulk deletion.
struct NativBulkSelectionToolbar<Actions: View>: View {
    let selectedCount: Int
    let allSelected: Bool
    var isSelectAllEnabled = true
    let onToggleAll: () -> Void
    let onDelete: () -> Void
    let actions: Actions

    init(
        selectedCount: Int,
        allSelected: Bool,
        isSelectAllEnabled: Bool = true,
        onToggleAll: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.selectedCount = selectedCount
        self.allSelected = allSelected
        self.isSelectAllEnabled = isSelectAllEnabled
        self.onToggleAll = onToggleAll
        self.onDelete = onDelete
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(selectedCount) selected")
                .nativTextStyle(.actionLabel)
                .foregroundStyle(.secondary)

            Button(allSelected ? "Deselect All" : "Select All", action: onToggleAll)
                .disabled(!isSelectAllEnabled)

            Spacer(minLength: 0)

            actions

            Button(role: .destructive, action: onDelete) {
                Label("Delete Selected", systemImage: "trash")
            }
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

extension NativBulkSelectionToolbar where Actions == EmptyView {
    init(
        selectedCount: Int,
        allSelected: Bool,
        isSelectAllEnabled: Bool = true,
        onToggleAll: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.init(
            selectedCount: selectedCount,
            allSelected: allSelected,
            isSelectAllEnabled: isSelectAllEnabled,
            onToggleAll: onToggleAll,
            onDelete: onDelete
        ) {
            EmptyView()
        }
    }
}
