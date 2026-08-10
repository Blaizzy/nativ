import NativServerKit
import SwiftUI

struct NativKitEditor: View {
    @ObservedObject var manager: NativExtensionManager
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    let onSave: (UserNativKit) -> Void
    let onCancel: () -> Void

    @State private var draft: UserNativKit

    init(
        kit: UserNativKit,
        manager: NativExtensionManager,
        host: MCPHostManager,
        model: NativModel,
        onSave: @escaping (UserNativKit) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: kit)
        self.manager = manager
        self.host = host
        self.model = model
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool { draft.normalized().isComplete }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "New kit" : draft.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                NativHoverCloseButton { onCancel() }
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identityFields
                    components
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft.normalized()) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
    }

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorField("Name") {
                TextField("Kit name", text: $draft.name)
                    .textFieldStyle(.plain)
            }
            editorField("Description") {
                TextField("What is this kit for?", text: $draft.summary)
                    .textFieldStyle(.plain)
            }
        }
    }

    private var components: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Capabilities")
                .font(.system(size: 15, weight: .semibold))

            if !availableExtensions.isEmpty {
                componentSection(
                    title: "Extensions",
                    caption: "Extension features this kit makes available."
                ) {
                    ForEach(availableExtensions) { record in
                        componentToggle(
                            record.manifest.displayName,
                            isOn: containsBinding(record.id, in: \UserNativKit.extensionIDs)
                        )
                    }
                }
            }

            if !configuredServers.isEmpty {
                componentSection(
                    title: "MCP servers and tools",
                    caption: "Selecting a tool also includes the server it needs."
                ) {
                    ForEach(configuredServers) { server in
                        VStack(alignment: .leading, spacing: 5) {
                            componentToggle(
                                server.name.isEmpty ? server.command : server.name,
                                isOn: serverBinding(server.id)
                            )
                            let tools = host.hostedTools(forServer: server.id)
                            if tools.isEmpty, server.isEnabled {
                                Text("No connected tools are available right now.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 24)
                            } else {
                                ForEach(tools) { tool in
                                    Toggle(tool.name, isOn: mcpToolBinding(serverID: server.id, name: tool.name))
                                        .toggleStyle(.checkbox)
                                        .font(.system(size: 12, design: .monospaced))
                                        .padding(.leading, 24)
                                }
                            }
                        }
                    }
                }
            }

            componentSection(
                title: "Built-in tools",
                caption: "Tools provided directly by Nativ."
            ) {
                ForEach(builtInToolNames, id: \.self) { name in
                    componentToggle(
                        name,
                        isOn: containsBinding(name, in: \UserNativKit.builtInToolNames)
                    )
                }
            }

            if !model.settings.customTools.isEmpty {
                componentSection(
                    title: "Custom tools",
                    caption: "Endpoint tools can run in routines. Script tools still require an interactive chat."
                ) {
                    ForEach(model.settings.customTools) { tool in
                        componentToggle(
                            tool.name,
                            isOn: containsBinding(tool.id, in: \UserNativKit.customToolIDs)
                        )
                    }
                }
            }

            if !availableSkills.isEmpty {
                componentSection(
                    title: "Skills",
                    caption: "Instructions added while the kit is in use."
                ) {
                    ForEach(availableSkills) { skill in
                        componentToggle(
                            skill.name,
                            isOn: containsBinding(skill.id, in: \UserNativKit.skillIDs)
                        )
                    }
                }
            }

            unavailableSelections
        }
    }

    @ViewBuilder
    private var unavailableSelections: some View {
        let serverIDs = Set(configuredServers.map(\.id))
        let unavailableServers = draft.mcpServerIDs.filter { !serverIDs.contains($0) }
        let availableTools = Set(configuredServers.flatMap { server in
            host.hostedTools(forServer: server.id).map {
                NativKitMCPTool(serverID: server.id, name: $0.name)
            }
        })
        let unavailableTools = draft.mcpTools.filter { tool in
            guard serverIDs.contains(tool.serverID) else { return true }
            guard case .connected = host.states[tool.serverID] else { return false }
            return !availableTools.contains(tool)
        }
        let skillIDs = Set(availableSkills.map(\.id))
        let unavailableSkills = draft.skillIDs.filter { !skillIDs.contains($0) }
        let customToolIDs = Set(model.settings.customTools.map(\.id))
        let unavailableCustomTools = draft.customToolIDs.filter { !customToolIDs.contains($0) }
        let extensionIDs = Set(availableExtensions.map(\.id))
        let unavailableExtensions = draft.extensionIDs.filter { !extensionIDs.contains($0) }
        if !unavailableServers.isEmpty
            || !unavailableTools.isEmpty
            || !unavailableSkills.isEmpty
            || !unavailableCustomTools.isEmpty
            || !unavailableExtensions.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("Some saved capabilities are no longer available", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                Text("You can keep their identifiers in case they are reinstalled, or remove them from this kit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove unavailable") {
                    draft.mcpServerIDs.removeAll { unavailableServers.contains($0) }
                    draft.mcpTools.removeAll {
                        unavailableServers.contains($0.serverID) || unavailableTools.contains($0)
                    }
                    draft.skillIDs.removeAll { unavailableSkills.contains($0) }
                    draft.customToolIDs.removeAll { unavailableCustomTools.contains($0) }
                    draft.extensionIDs.removeAll { unavailableExtensions.contains($0) }
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var availableExtensions: [NativExtensionRecord] {
        manager.records.filter { !$0.isRemoved }
    }

    private var configuredServers: [MCPServerConfig] {
        model.settings.mcpServers.filter {
            !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var availableSkills: [NativSkill] {
        model.settings.skills.filter { $0.id != NativSkill.builtInToolGuideID }
    }

    private var builtInToolNames: [String] {
        ChatToolRegistry.definitions(canEditImage: false).map(\.function.name)
    }

    private func serverBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.mcpServerIDs.contains(id) },
            set: { selected in
                if selected {
                    if !draft.mcpServerIDs.contains(id) { draft.mcpServerIDs.append(id) }
                } else {
                    draft.mcpServerIDs.removeAll { $0 == id }
                    draft.mcpTools.removeAll { $0.serverID == id }
                }
            }
        )
    }

    private func mcpToolBinding(serverID: UUID, name: String) -> Binding<Bool> {
        let reference = NativKitMCPTool(serverID: serverID, name: name)
        return Binding(
            get: { draft.mcpTools.contains(reference) },
            set: { selected in
                if selected {
                    if !draft.mcpTools.contains(reference) { draft.mcpTools.append(reference) }
                    if !draft.mcpServerIDs.contains(serverID) { draft.mcpServerIDs.append(serverID) }
                } else {
                    draft.mcpTools.removeAll { $0 == reference }
                }
            }
        )
    }

    private func containsBinding<Value: Hashable>(
        _ value: Value,
        in keyPath: WritableKeyPath<UserNativKit, [Value]>
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].contains(value) },
            set: { selected in
                if selected {
                    if !draft[keyPath: keyPath].contains(value) {
                        draft[keyPath: keyPath].append(value)
                    }
                } else {
                    draft[keyPath: keyPath].removeAll { $0 == value }
                }
            }
        )
    }

    @ViewBuilder
    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func componentSection<Content: View>(
        title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func componentToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
    }
}
