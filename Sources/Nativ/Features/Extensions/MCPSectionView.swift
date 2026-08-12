import NativServerKit
import SwiftUI

struct MCPSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var editing: MCPServerConfig?
    @State private var pendingDelete: MCPServerConfig?

    private let catalog = MCPServerCatalog.bundled

    var body: some View {
        HubSectionScaffold(
            title: "MCP",
            subtitle: "Connect Model Context Protocol servers so tool-capable models can use their tools."
        ) {
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
            onDelete: { pendingDelete = server }
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
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
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
        .padding(.vertical, 11)
    }

    private var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    private var statusTone: NativStatusTone {
        switch state {
        case .connected: .success
        case .connecting: .warning
        case .failed: .danger
        case .disabled, .none: .neutral
        }
    }

    private var statusText: String {
        switch state {
        case .connected(let count): "\(count) tool\(count == 1 ? "" : "s")"
        case .connecting: "Connecting\u{2026}"
        case .failed(let message): message.isEmpty ? "Failed to connect" : message
        case .disabled: "Off"
        case .none: server.isEnabled ? "Not connected" : "Off"
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
