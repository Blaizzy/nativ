import NativServerKit
import SwiftUI

struct MCPSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var editing: MCPServerConfig?
    @State private var showingCatalog = false

    var body: some View {
        HubSectionScaffold(
            title: "MCP",
            subtitle: "Connect Model Context Protocol servers so tool-capable models can use their tools."
        ) {
            HStack(spacing: 8) {
                Button {
                    showingCatalog = true
                } label: {
                    Label("Browse catalog", systemImage: "square.grid.2x2")
                }
                Button {
                    editing = MCPServerConfig(name: "", isEnabled: true)
                } label: {
                    Label("Add your own", systemImage: "plus")
                }
            }
        } content: {
            if model.settings.mcpServers.isEmpty {
                HubEmptyHint(
                    icon: "server.rack",
                    text: "No servers yet. Add your own, or browse the community catalog of approved servers."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.settings.mcpServers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider() }
                        MCPServerRow(
                            server: server,
                            state: host.states[server.id],
                            onToggle: { toggle(server) },
                            onReconnect: { host.reconnect(server.id) },
                            onEdit: { editing = server },
                            onDelete: { delete(server) }
                        )
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
        .sheet(isPresented: $showingCatalog) {
            MCPCatalogView(
                installedNames: Set(model.settings.mcpServers.map(\.name))
            ) { entry in
                save(entry.makeConfig())
            }
        }
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
    let onReconnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .opacity(isConnecting && pulse ? 0.35 : 1)
                .animation(
                    isConnecting
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? "Untitled server" : server.name)
                    .font(.system(size: 13, weight: .medium))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if server.isEnabled {
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

    private var statusColor: Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disabled, .none: Color(nsColor: .tertiaryLabelColor)
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
  "name": "",
  "command": "",
  "args": [],
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
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
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

// MARK: - Community catalog
//
// A catalog entry mirrors an approved community `manifest.yaml` plus a logo.
// A future community PR contributes a manifest + a logo image (dropped into
// Assets.xcassets as `MCPLogo-<name>`); until an asset exists we render a
// tinted glyph tile so the grid always looks complete.

struct MCPCatalogEntry: Identifiable {
    let id = UUID()
    let name: String
    let summary: String
    let command: String
    let arguments: [String]
    let symbol: String
    let tint: Color
    var logoAssetName: String { "MCPLogo-\(name)" }

    func makeConfig() -> MCPServerConfig {
        MCPServerConfig(name: name, command: command, arguments: arguments, isEnabled: true)
    }
}

private let mcpCatalog: [MCPCatalogEntry] = [
    .init(name: "filesystem", summary: "Read and write files in allowed folders.",
          command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "."],
          symbol: "folder.fill", tint: .blue),
    .init(name: "git", summary: "Inspect and operate on Git repositories.",
          command: "uvx", arguments: ["mcp-server-git"],
          symbol: "arrow.triangle.branch", tint: .orange),
    .init(name: "github", summary: "Search and manage GitHub issues, PRs, and code.",
          command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"],
          symbol: "chevron.left.forwardslash.chevron.right", tint: .primary),
    .init(name: "fetch", summary: "Fetch and read web pages as markdown.",
          command: "uvx", arguments: ["mcp-server-fetch"],
          symbol: "globe", tint: .teal),
    .init(name: "memory", summary: "A persistent knowledge graph the model can recall.",
          command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"],
          symbol: "brain.head.profile", tint: .purple),
    .init(name: "sqlite", summary: "Query and edit a local SQLite database.",
          command: "uvx", arguments: ["mcp-server-sqlite", "--db-path", "database.db"],
          symbol: "cylinder.split.1x2", tint: .green),
]

/// A square logo: the bundled `MCPLogo-<name>` image if present, otherwise a
/// tinted rounded tile with the entry's glyph.
private struct MCPLogoTile: View {
    let entry: MCPCatalogEntry
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let nsImage = NSImage(named: entry.logoAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.16)
            } else {
                Image(systemName: entry.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(entry.tint)
            }
        }
        .frame(width: size, height: size)
        .background(entry.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

private struct MCPCatalogView: View {
    let installedNames: Set<String>
    let onAdd: (MCPCatalogEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hoveringClose = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Community catalog")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Native-sponsored servers, approved and merged into Nativ. Adding one launches it locally the first time you connect.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                closeButton
            }
            .padding(24)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(mcpCatalog) { entry in
                        MCPCatalogCard(
                            entry: entry,
                            isAdded: installedNames.contains(entry.name),
                            onAdd: { onAdd(entry) }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 720, height: 560)
    }

    private var closeButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.primary.opacity(hoveringClose ? 0.10 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .help("Close")
    }
}

private struct MCPCatalogCard: View {
    let entry: MCPCatalogEntry
    let isAdded: Bool
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                MCPLogoTile(entry: entry)
                Spacer(minLength: 0)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .help("Native-sponsored")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(entry.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if isAdded {
                Label("Added", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(action: onAdd) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(height: 168, alignment: .topLeading)
        .background(Color.primary.opacity(hovering ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
    }
}
