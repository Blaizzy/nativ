import AppKit
import NativExtensionSDK
import NativServerKit
import SwiftUI

struct ExtensionsHubView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var section: HubSection = .kits
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
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard !didLaunch else { return }
            didLaunch = true
            manager.launch(
                context: NativExtensionHostContext(
                    transcriptionConfiguration: { nil },
                    openSpeechModels: {},
                    showMainWindow: {}
                )
            )
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
        .padding(12)
        .frame(width: 188)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .kits:
            KitsSectionView(manager: manager, host: host, model: model)
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
                            .font(.system(size: 20, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    action()
                }
                content()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
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

    var body: some View {
        HubSectionScaffold(
            title: "Extensions",
            subtitle: "Packages that add features to Nativ."
        ) {
            EmptyView()
        } content: {
            if manager.records.isEmpty {
                HubEmptyHint(
                    icon: "square.stack.3d.up.slash",
                    text: "No extensions installed."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(manager.records) { record in
                        ExtensionRow(record: record, manager: manager)
                    }
                }
            }
        }
        .onAppear {
            manager.refreshPermissionStatuses()
        }
    }
}

private struct ExtensionRow: View {
    let record: NativExtensionRecord
    @ObservedObject var manager: NativExtensionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                NativTintedIconTile(symbol: record.manifest.systemImage, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.manifest.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        if record.isIncluded { includedBadge }
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
    @ObservedObject var model: NativModel
    @State private var editing: NativSkill?
    @State private var pendingDelete: NativSkill?

    var body: some View {
        HubSectionScaffold(
            title: "Skills",
            subtitle: "Reusable instructions the model can apply."
        ) {
            Button {
                editing = NativSkill()
            } label: {
                Label("Add skill", systemImage: "plus")
            }
        } content: {
            VStack(spacing: 0) {
                SkillRow(
                    skill: NativSkill.builtInToolGuide,
                    isBuiltIn: true,
                    onToggle: {},
                    onEdit: {},
                    onDelete: {}
                )
                ForEach(model.settings.skills) { skill in
                    Divider()
                    SkillRow(
                        skill: skill,
                        onToggle: { toggle(skill) },
                        onEdit: { editing = skill },
                        onDelete: { pendingDelete = skill }
                    )
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
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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
