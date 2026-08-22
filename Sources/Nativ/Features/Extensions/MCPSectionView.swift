import AppKit
import NativServerKit
import SwiftUI

struct MCPSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var editing: MCPServerConfig?
    @State private var pendingDelete: MCPServerConfig?
    @State private var customServerSelection = NativBulkSelection<MCPServerConfig.ID>()
    @State private var pendingCustomServerDeletion: [MCPServerConfig] = []
    @State private var isConfirmingCustomServerDeletion = false

    private let catalog = MCPServerCatalog.bundled

    var body: some View {
        HubSectionScaffold(
            title: "MCP",
            subtitle: "Connect Model Context Protocol servers so tool-capable models can use their tools."
        ) {
            Button(customServerSelection.isActive ? "Done" : "Select") {
                customServerSelection.toggleMode()
            }
            .disabled(customServers.isEmpty)

            Button {
                editing = MCPServerConfig(name: "", isEnabled: true)
            } label: {
                Label("Add your own", systemImage: "plus")
            }
        } content: {
            if catalog.entries.isEmpty && customServers.isEmpty {
                HubEmptyHint(
                    icon: "server.rack",
                    text: "No built-in servers are available. You can still add your own MCP server."
                )
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    if !catalog.entries.isEmpty {
                        serverGroup(title: "Built in") {
                            ForEach(Array(catalog.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider() }
                                builtInServerRow(entry)
                            }
                        }
                    }

                    serverGroup(title: "Custom") {
                        if customServers.isEmpty {
                            Text("No custom servers added.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 11)
                        } else {
                            if customServerSelection.isActive {
                                customServerSelectionBar
                                    .padding(.bottom, 8)
                            }
                            ForEach(Array(customServers.enumerated()), id: \.element.id) { index, server in
                                if index > 0 { Divider() }
                                configuredServerRow(server)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .alert(
            "Delete MCP server?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { server in
            Button("Delete", role: .destructive) {
                delete(server)
                pendingDelete = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { server in
            Text("“\(server.name.isEmpty ? "This server" : server.name)” and its configuration will be removed.")
        }
        .alert(
            "Delete \(pendingCustomServerDeletion.count) MCP \(pendingCustomServerDeletion.count == 1 ? "server" : "servers")?",
            isPresented: $isConfirmingCustomServerDeletion
        ) {
            Button("Delete", role: .destructive) {
                let ids = Set(pendingCustomServerDeletion.map(\.id))
                model.settings.mcpServers.removeAll { ids.contains($0.id) }
                customServerSelection.finish()
                pendingCustomServerDeletion = []
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {
                pendingCustomServerDeletion = []
            }
        } message: {
            Text("The selected MCP server configurations will be removed.")
        }
    }

    private var customServers: [MCPServerConfig] {
        catalog.customServers(in: model.settings.mcpServers).filter {
            !$0.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @ViewBuilder
    private func serverGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            content()
        }
    }

    private func builtInServerRow(_ entry: MCPCatalogEntry) -> some View {
        let configured = catalog.configuredServer(
            for: entry,
            in: model.settings.mcpServers
        )
        let presentation = configured ?? entry.makeConfiguration(isEnabled: false)

        return MCPServerRow(
            server: presentation,
            state: configured.flatMap { host.states[$0.id] } ?? .disabled,
            onToggle: { toggle(entry) },
            onReconnect: configured.map { server in { host.reconnect(server.id) } },
            onEdit: { editing = presentation },
            onDelete: configured.map { server in { pendingDelete = server } }
        )
    }

    private func configuredServerRow(_ server: MCPServerConfig) -> some View {
        MCPServerRow(
            server: server,
            state: host.states[server.id],
            onToggle: { toggle(server) },
            onReconnect: { host.reconnect(server.id) },
            onEdit: { editing = server },
            isSelecting: customServerSelection.isActive,
            isSelected: customServerSelection.contains(server.id),
            onToggleSelection: { customServerSelection.toggle(server.id) },
            onDelete: { pendingDelete = server }
        )
    }

    private var selectedCustomServers: [MCPServerConfig] {
        customServers.filter { customServerSelection.contains($0.id) }
    }

    private var customServerSelectionBar: some View {
        let selections = selectedCustomServers
        let serverIDs = Set(customServers.map(\.id))
        return NativBulkSelectionToolbar(
            selectedCount: selections.count,
            allSelected: customServerSelection.includesAll(serverIDs),
            onToggleAll: {
                customServerSelection.toggleAll(serverIDs)
            },
            onDelete: {
                pendingCustomServerDeletion = selections
                isConfirmingCustomServerDeletion = true
            }
        )
    }

    private func toggle(_ entry: MCPCatalogEntry) {
        var servers = model.settings.mcpServers
        catalog.setEnabled(
            !catalog.isEnabled(entry, in: servers),
            for: entry,
            in: &servers
        )
        model.settings.mcpServers = servers
    }

    private func toggle(_ server: MCPServerConfig) {
        guard let i = model.settings.mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        model.settings.mcpServers[i].isEnabled.toggle()
    }

    private func delete(_ server: MCPServerConfig) {
        model.settings.mcpServers.removeAll { $0.id == server.id }
    }

    private func save(_ server: MCPServerConfig) {
        if let i = model.settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
            model.settings.mcpServers[i] = server
        } else {
            model.settings.mcpServers.append(server)
        }
    }
}

// MARK: - Server row

private struct MCPServerRow: View {
    let server: MCPServerConfig
    let state: MCPServerConnectionState?
    let onToggle: () -> Void
    let onReconnect: (() -> Void)?
    let onEdit: () -> Void
    var isSelecting = false
    var isSelected = false
    var onToggleSelection: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var copiedAuthorizationCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: showsGitHubSetup ? 10 : 0) {
            HStack(spacing: 12) {
                if isSelecting, onToggleSelection != nil {
                    NativBulkSelectionCheckbox(isSelected: isSelected)
                }

                NativStatusDot(tone: statusTone, pulsing: isConnecting)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name.isEmpty ? "Untitled server" : server.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if server.isEnabled, let onReconnect {
                    Button(action: onReconnect) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reconnect")
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit")
                if let onDelete {
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
                }
                Toggle("", isOn: Binding(get: { server.isEnabled }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if case .authorizingGitHub(let code, let verificationURL) = state {
                GitHubSetupCallout(
                    icon: "key.fill",
                    title: "Authorize Nativ on GitHub",
                    message: "Enter this one-time code on GitHub to continue.",
                    actionTitle: "Open GitHub",
                    actionIcon: "arrow.up.right",
                    destination: verificationURL
                ) {
                    HStack(spacing: 6) {
                        Text(code)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button {
                            copyAuthorizationCode(code)
                        } label: {
                            Label(
                                copiedAuthorizationCode ? "Copied" : "Copy code",
                                systemImage: copiedAuthorizationCode ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 20)
            } else if case .installingGitHub(let installationURL) = state {
                GitHubSetupCallout(
                    icon: "folder.badge.plus",
                    title: "Choose repository access",
                    message: "GitHub authorization is complete. Select which repositories Nativ can use. You can change this later on GitHub.",
                    actionTitle: "Choose repositories",
                    actionIcon: "arrow.up.right",
                    destination: installationURL
                )
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 11)
        .nativBulkSelectable(
            isSelecting: isSelecting && onToggleSelection != nil,
            isSelected: isSelected,
            cornerRadius: 8,
            accessibilityLabel: "Select \(server.name.isEmpty ? "Untitled server" : server.name)",
            action: onToggleSelection ?? {}
        )
    }

    private var showsGitHubSetup: Bool {
        if case .authorizingGitHub = state { return true }
        if case .installingGitHub = state { return true }
        return false
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        if case .authorizingGitHub = state { return true }
        if case .installingGitHub = state { return true }
        return false
    }

    private var statusTone: NativStatusTone {
        switch state {
        case .connected: .success
        case .connecting, .authorizingGitHub, .installingGitHub: .warning
        case .failed: .danger
        case .disabled, .none: .neutral
        }
    }

    private var statusText: String {
        switch state {
        case .connected(let count): "\(count) tool\(count == 1 ? "" : "s")"
        case .connecting: "Connecting\u{2026}"
        case .authorizingGitHub: "Authorization required"
        case .installingGitHub: "Repository access required"
        case .failed(let message): message.isEmpty ? "Failed to connect" : message
        case .disabled: "Off"
        case .none: server.isEnabled ? "Not connected" : "Off"
        }
    }

    private func copyAuthorizationCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copiedAuthorizationCode = true
    }
}

private struct GitHubSetupCallout<Accessory: View>: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let actionIcon: String
    let destination: URL
    @ViewBuilder let accessory: Accessory

    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        actionIcon: String,
        destination: URL,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionIcon = actionIcon
        self.destination = destination
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                accessory
            }

            Spacer(minLength: 12)

            Link(destination: destination) {
                Label(actionTitle, systemImage: actionIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 650, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }
}

private extension GitHubSetupCallout where Accessory == EmptyView {
    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        actionIcon: String,
        destination: URL
    ) {
        self.init(
            icon: icon,
            title: title,
            message: message,
            actionTitle: actionTitle,
            actionIcon: actionIcon,
            destination: destination
        ) {
            EmptyView()
        }
    }
}

// MARK: - Add / edit overlay

private struct MCPServerJSON: Codable {
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case command
        case arguments = "args"
        case environment = "env"
        case isEnabled
    }

    init(name: String, command: String, arguments: [String], environment: [String: String], isEnabled: Bool) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isEnabled = isEnabled
    }

    // Lenient: the scaffold and pasted standard mcp.json entries may omit name
    // and isEnabled.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        command = (try? c.decode(String.self, forKey: .command)) ?? ""
        arguments = (try? c.decode([String].self, forKey: .arguments)) ?? []
        environment = (try? c.decode([String: String].self, forKey: .environment)) ?? [:]
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
    }
}

private let mcpJSONScaffold = """
{
  "name": "filesystem",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/directory"],
  "env": {}
}
"""

private struct MCPServerEditor: View {
    let onSave: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var server: MCPServerConfig
    @State private var editingJSON: Bool
    @State private var jsonText: String
    @State private var jsonError: String?

    init(server: MCPServerConfig, onSave: @escaping (MCPServerConfig) -> Void, onCancel: @escaping () -> Void) {
        _server = State(initialValue: server)
        self.onSave = onSave
        self.onCancel = onCancel
        // A brand-new server (nothing filled in) opens straight into a
        // pre-bracketed JSON scaffold so you can just type — or paste a
        // standard mcp.json entry.
        let isNew = server.name.isEmpty && server.command.isEmpty && server.arguments.isEmpty
        _editingJSON = State(initialValue: isNew)
        _jsonText = State(initialValue: isNew ? mcpJSONScaffold : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(server.name.isEmpty ? "New MCP Server" : "Edit MCP Server")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("Edit as JSON", isOn: $editingJSON)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: editingJSON) { _, on in
                        if on { jsonText = currentJSON() } else { applyJSON() }
                    }
            }

            if editingJSON {
                TextEditor(text: $jsonText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                if let jsonError {
                    Text(jsonError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            } else {
                field("Name") {
                    TextField("e.g. filesystem", text: $server.name)
                        .textFieldStyle(.roundedBorder)
                }
                field("Command") {
                    TextField("e.g. npx", text: $server.command)
                        .textFieldStyle(.roundedBorder)
                }
                field("Arguments (one per line)") {
                    TextEditor(text: argumentsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
                field("Environment (KEY=VALUE per line)") {
                    TextEditor(text: environmentText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    if editingJSON { applyJSON() }
                    guard jsonError == nil else { return }
                    onSave(server)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    server.name.trimmingCharacters(in: .whitespaces).isEmpty
                        || server.command.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private var argumentsText: Binding<String> {
        Binding(
            get: { server.arguments.joined(separator: "\n") },
            set: { server.arguments = $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        )
    }

    private var environmentText: Binding<String> {
        Binding(
            get: { server.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") },
            set: { raw in
                var env: [String: String] = [:]
                for line in raw.split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { env[key] = value }
                }
                server.environment = env
            }
        )
    }

    private func currentJSON() -> String {
        let payload = MCPServerJSON(
            name: server.name,
            command: server.command,
            arguments: server.arguments,
            environment: server.environment,
            isEnabled: server.isEnabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func applyJSON() {
        guard let data = jsonText.data(using: .utf8) else { return }
        do {
            let payload = try JSONDecoder().decode(MCPServerJSON.self, from: data)
            server.name = payload.name
            server.command = payload.command
            server.arguments = payload.arguments
            server.environment = payload.environment
            server.isEnabled = payload.isEnabled
            jsonError = nil
        } catch {
            jsonError = "Invalid JSON: \(error.localizedDescription)"
        }
    }
}
