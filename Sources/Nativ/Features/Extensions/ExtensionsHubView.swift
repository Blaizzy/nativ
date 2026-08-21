import AppKit
import NativExtensionSDK
import NativServerKit
import SwiftUI

struct ExtensionsHubView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    var model: NativModel
    @Binding var section: HubSection
    @State private var didLaunch = false

    enum HubSection: String, CaseIterable, Identifiable {
        case kits = "Kits"
        case extensions = "Extensions"
        case mcp = "MCP"
        case tools = "Tools"
        case skills = "Skills"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .kits: "shippingbox"
            case .extensions: "square.stack.3d.up"
            case .mcp: "server.rack"
            case .tools: "hammer"
            case .skills: "sparkles"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            subnav
            Divider()
                .ignoresSafeArea(.container, edges: .top)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard !didLaunch else { return }
            didLaunch = true
            host.reload(servers: model.settings.mcpServers)
        }
        .onChange(of: model.settings.mcpServers) { _, servers in
            host.reload(servers: servers)
        }
    }

    private var subnav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HubSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .frame(width: 18)
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                    .background(
                        section == item ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .controlPanelDetailHeaderTopPadding()
        .padding(.bottom, 12)
        .frame(width: 188)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .kits:
            KitsSectionView(manager: manager, model: model)
        case .extensions:
            ExtensionsSectionView(manager: manager)
        case .mcp:
            MCPSectionView(host: host, model: model)
        case .tools:
            ToolsSectionView(host: host, model: model)
        case .skills:
            SkillsSectionView(model: model)
        }
    }
}

private struct OpenExtensionsHubSectionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (
        ExtensionsHubView.HubSection
    ) -> Void = { _ in }
}

extension EnvironmentValues {
    var openExtensionsHubSection: @MainActor @Sendable (
        ExtensionsHubView.HubSection
    ) -> Void {
        get { self[OpenExtensionsHubSectionKey.self] }
        set { self[OpenExtensionsHubSectionKey.self] = newValue }
    }
}

// MARK: - Shared flat primitives

struct HubSectionScaffold<Content: View, Action: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    action()
                }
                content()
            }
            .padding(.horizontal, 28)
            .controlPanelDetailHeaderTopPadding()
            .padding(.bottom, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HubEmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Extensions section

private struct ExtensionsSectionView: View {
    @ObservedObject var manager: NativExtensionManager
    @State private var extensionSelection = NativBulkSelection<NativExtensionRecord.ID>()
    @State private var pendingExtensionRemoval: [NativExtensionRecord] = []
    @State private var isConfirmingExtensionRemoval = false

    private var removableExtensions: [NativExtensionRecord] {
        manager.records.filter { !$0.isRemoved }
    }

    private var selectedExtensions: [NativExtensionRecord] {
        removableExtensions.filter { extensionSelection.contains($0.id) }
    }

    var body: some View {
        HubSectionScaffold(
            title: "Extensions",
            subtitle: "Packages that add features to Nativ."
        ) {
            Button(extensionSelection.isActive ? "Done" : "Select") {
                extensionSelection.toggleMode()
            }
            .disabled(removableExtensions.isEmpty)
        } content: {
            if manager.records.isEmpty {
                HubEmptyHint(
                    icon: "square.stack.3d.up.slash",
                    text: "No extensions installed."
                )
            } else {
                VStack(spacing: 12) {
                    if extensionSelection.isActive {
                        extensionSelectionBar
                    }
                    ForEach(manager.records) { record in
                        ExtensionRow(
                            record: record,
                            manager: manager,
                            isSelecting: extensionSelection.isActive && !record.isRemoved,
                            isSelected: extensionSelection.contains(record.id),
                            onToggleSelection: { extensionSelection.toggle(record.id) },
                            onRemove: {
                                pendingExtensionRemoval = [record]
                                isConfirmingExtensionRemoval = true
                            }
                        )
                    }
                }
            }
        }
        .onAppear {
            manager.refreshPermissionStatuses()
        }
        .alert(
            "Remove \(pendingExtensionRemoval.count) \(pendingExtensionRemoval.count == 1 ? "extension" : "extensions")?",
            isPresented: $isConfirmingExtensionRemoval
        ) {
            Button("Remove", role: .destructive) {
                let ids = pendingExtensionRemoval.map(\.id)
                ids.forEach { manager.remove(extensionID: $0) }
                extensionSelection.finish()
                pendingExtensionRemoval = []
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingExtensionRemoval = []
            }
        } message: {
            Text("External packages will be deleted from disk. Included and system extensions can be restored later.")
        }
    }

    private var extensionSelectionBar: some View {
        let selections = selectedExtensions
        let removableIDs = Set(removableExtensions.map(\.id))
        return NativBulkSelectionToolbar(
            selectedCount: selections.count,
            allSelected: extensionSelection.includesAll(removableIDs),
            deleteTitle: "Remove",
            onToggleAll: {
                extensionSelection.toggleAll(removableIDs)
            },
            onDelete: {
                pendingExtensionRemoval = selections
                isConfirmingExtensionRemoval = true
            }
        )
    }
}

private struct ExtensionRow: View {
    let record: NativExtensionRecord
    @ObservedObject var manager: NativExtensionManager
    var isSelecting = false
    var isSelected = false
    let onToggleSelection: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if isSelecting {
                    NativBulkSelectionCheckbox(isSelected: isSelected)
                }

                NativTintedIconTile(symbol: record.manifest.systemImage, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.manifest.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        if record.isIncluded { includedBadge }
                        if record.isRemoved { removedBadge }
                    }
                    Text(record.manifest.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Version \(record.manifest.version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
                Spacer(minLength: 12)
                if record.isRemoved {
                    Button("Restore") {
                        manager.restore(extensionID: record.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { record.isEnabled },
                            set: { manager.setEnabled($0, extensionID: record.id) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Menu {
                        Button("Remove", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 18)
                    .help("Manage extension")
                }
            }
            if !record.manifest.permissions.isEmpty {
                Divider()
                    .padding(.vertical, 14)
                permissions
            }
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .nativBulkSelectable(
            isSelecting: isSelecting,
            isSelected: isSelected,
            accessibilityLabel: "Select \(record.manifest.displayName)",
            action: onToggleSelection
        )
    }

    private var includedBadge: some View {
        Text("INCLUDED")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    private var removedBadge: some View {
        Text("REMOVED")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Permissions")
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 8) {
                ForEach(record.manifest.permissions, id: \.self) { permission in
                    permissionBadge(permission, extensionIsEnabled: record.isEnabled)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionBadge(
        _ permission: NativExtensionPermission,
        extensionIsEnabled: Bool
    ) -> some View {
        let status = manager.permissionStatus(permission)
        let actionTitle = extensionIsEnabled
            ? manager.permissionActionTitle(permission)
            : nil
        if let actionTitle {
            Button {
                manager.requestPermission(permission)
            } label: {
                permissionBadgeLabel(
                    permission: permission,
                    status: status,
                    actionTitle: actionTitle
                )
            }
            .buttonStyle(.plain)
            .help("\(actionTitle) \(permission.displayName) permission")
        } else {
            permissionBadgeLabel(
                permission: permission,
                status: status,
                actionTitle: nil
            )
        }
    }

    private func permissionBadgeLabel(
        permission: NativExtensionPermission,
        status: NativExtensionPermissionStatus,
        actionTitle: String?
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(permission.displayName)
            Text("· \(status.title)")
                .foregroundStyle(.secondary)
            if let actionTitle {
                Text(actionTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.045),
            in: Capsule()
        )
        .contentShape(Capsule())
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(
            proposal: proposal,
            subviews: subviews
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (
            CGSize(
                width: proposal.width ?? max(0, x - spacing),
                height: y + lineHeight
            ),
            points
        )
    }
}

// MARK: - Skills section

private struct SkillsSectionView: View {
    var model: NativModel
    @State private var editing: NativSkill?
    @State private var pendingDelete: NativSkill?
    @State private var skillSelection = NativBulkSelection<NativSkill.ID>()
    @State private var pendingSkillDeletion: [NativSkill] = []
    @State private var isConfirmingSkillDeletion = false

    var body: some View {
        HubSectionScaffold(
            title: "Skills",
            subtitle: "Reusable instructions the model can apply."
        ) {
            Button(skillSelection.isActive ? "Done" : "Select") {
                skillSelection.toggleMode()
            }
            .disabled(model.settings.skills.isEmpty)

            Button {
                editing = NativSkill()
            } label: {
                Label("Add skill", systemImage: "plus")
            }
        } content: {
            VStack(spacing: 0) {
                if model.settings.skills.isEmpty {
                    HubEmptyHint(
                        icon: "sparkles",
                        text: "No skills yet. Add reusable instructions the model can apply."
                    )
                } else {
                    if skillSelection.isActive {
                        skillSelectionBar
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(model.settings.skills.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 { Divider() }
                        SkillRow(
                            skill: skill,
                            isSelecting: skillSelection.isActive,
                            isSelected: skillSelection.contains(skill.id),
                            onToggle: { toggle(skill) },
                            onEdit: { editing = skill },
                            onToggleSelection: { skillSelection.toggle(skill.id) },
                            onDelete: { pendingDelete = skill }
                        )
                    }
                }
            }
        }
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .alert(
            "Delete skill?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { skill in
            Button("Delete", role: .destructive) {
                delete(skill)
                pendingDelete = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { skill in
            Text("“\(skill.name.isEmpty ? "This skill" : skill.name)” will be permanently deleted.")
        }
        .alert(
            "Delete \(pendingSkillDeletion.count) \(pendingSkillDeletion.count == 1 ? "skill" : "skills")?",
            isPresented: $isConfirmingSkillDeletion
        ) {
            Button("Delete", role: .destructive) {
                let ids = Set(pendingSkillDeletion.map(\.id))
                model.settings.skills.removeAll { ids.contains($0.id) }
                skillSelection.finish()
                pendingSkillDeletion = []
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingSkillDeletion = []
            }
        } message: {
            Text("The selected skills will be permanently deleted.")
        }
    }

    private var selectedSkills: [NativSkill] {
        model.settings.skills.filter { skillSelection.contains($0.id) }
    }

    private var skillSelectionBar: some View {
        let selections = selectedSkills
        let skillIDs = Set(model.settings.skills.map(\.id))
        return NativBulkSelectionToolbar(
            selectedCount: selections.count,
            allSelected: skillSelection.includesAll(skillIDs),
            onToggleAll: {
                skillSelection.toggleAll(skillIDs)
            },
            onDelete: {
                pendingSkillDeletion = selections
                isConfirmingSkillDeletion = true
            }
        )
    }

    private func toggle(_ skill: NativSkill) {
        guard let i = model.settings.skills.firstIndex(where: { $0.id == skill.id }) else { return }
        model.settings.skills[i].isEnabled.toggle()
    }

    private func delete(_ skill: NativSkill) {
        model.settings.skills.removeAll { $0.id == skill.id }
    }

    private func save(_ skill: NativSkill) {
        if let i = model.settings.skills.firstIndex(where: { $0.id == skill.id }) {
            model.settings.skills[i] = skill
        } else {
            model.settings.skills.append(skill)
        }
    }
}

private struct SkillRow: View {
    let skill: NativSkill
    var isBuiltIn: Bool = false
    var isSelecting = false
    var isSelected = false
    let onToggle: () -> Void
    let onEdit: () -> Void
    var onToggleSelection: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting, onToggleSelection != nil {
                NativBulkSelectionCheckbox(isSelected: isSelected)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name.isEmpty ? "Untitled skill" : skill.name)
                    .font(.system(size: 13, weight: .medium))
                Text(skill.instructions)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if isBuiltIn {
                Text("Built-in")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            } else {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                Toggle("", isOn: Binding(get: { skill.isEnabled }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 11)
        .nativBulkSelectable(
            isSelecting: isSelecting && onToggleSelection != nil,
            isSelected: isSelected,
            cornerRadius: 8,
            accessibilityLabel: "Select \(skill.name.isEmpty ? "Untitled skill" : skill.name)",
            action: onToggleSelection ?? {}
        )
    }
}

private struct SkillEditor: View {
    @State var skill: NativSkill
    let onSave: (NativSkill) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(skill.name.isEmpty ? "New Skill" : "Edit Skill")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("e.g. Concise replies", text: $skill.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $skill.instructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(skill) }
                    .buttonStyle(.borderedProminent)
                    .disabled(skill.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
