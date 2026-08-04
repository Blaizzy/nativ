import AppKit
import NativExtensionSDK
import NativServerKit
import SwiftUI

struct ExtensionsHubView: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var section: HubSection = .extensions
    @State private var didLaunch = false

    enum HubSection: String, CaseIterable, Identifiable {
        case extensions = "Extensions"
        case mcp = "MCP"
        case tools = "Tools"
        case skills = "Skills"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
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
            Button {
                installPackage()
            } label: {
                Label("Install\u{2026}", systemImage: "plus")
            }
        } content: {
            if manager.records.isEmpty {
                HubEmptyHint(
                    icon: "square.stack.3d.up.slash",
                    text: "No extensions installed. Install a .nativextension package to add features."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(manager.records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        ExtensionRow(record: record, manager: manager)
                    }
                }
            }
        }
    }

    private func installPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.installPackage(at: url)
    }
}

private struct ExtensionRow: View {
    let record: NativExtensionRecord
    @ObservedObject var manager: NativExtensionManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.manifest.systemImage)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.manifest.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(record.manifest.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
        .padding(.vertical, 11)
    }
}

// MARK: - Skills section

private struct SkillsSectionView: View {
    @ObservedObject var model: NativModel
    @State private var editing: NativSkill?

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
                        onDelete: { delete(skill) }
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
