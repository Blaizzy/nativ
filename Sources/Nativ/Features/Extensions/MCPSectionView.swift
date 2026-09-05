import AppKit
import NativServerKit
import SwiftUI

struct MCPSectionView: View {
    @ObservedObject var host: MCPHostManager
    var model: NativModel
    @State private var editing: MCPServerConfig?
    @State private var pendingDelete: MCPServerConfig?

    private let catalog = MCPServerCatalog.bundled

    var body: some View {
        HubSectionScaffold(
            title: "MCP",
            subtitle: "Connect MCP servers without adding every tool to every model prompt."
        ) {
            Button {
                editing = MCPServerConfig(name: "", isEnabled: true)
            } label: {
                Label("Add MCP Server", systemImage: "plus")
            }
        } content: {
            if catalog.entries.isEmpty && customServers.isEmpty {
                HubEmptyHint(
                    icon: "server.rack",
                    text: "No built-in servers are available. You can still add your own MCP server."
                )
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ToolExposureModeExplanation()
                    if !catalog.entries.isEmpty {
                        serverGroup(title: "Built-in") {
                            ForEach(Array(catalog.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider() }
                                builtInServerRow(entry)
                            }
                        }
                    }

                    serverGroup(title: "Custom") {
                        if customServers.isEmpty {
                            Text("No custom servers have been added.")
                                .nativTextStyle(.supporting)
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
                .nativTextStyle(.subsectionTitle)
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
            exposureMode: Binding(
                get: {
                    guard let server = catalog.configuredServer(for: entry, in: model.settings.mcpServers)
                    else { return .off }
                    return model.settings.mcpServerExposureMode(for: server)
                },
                set: { setExposureMode($0, for: entry) }
            ),
            onReconnect: configured.map { server in { host.reconnect(server.id) } },
            onEdit: { editing = presentation },
            onDelete: configured.map { server in { pendingDelete = server } }
        )
    }

    private func configuredServerRow(_ server: MCPServerConfig) -> some View {
        MCPServerRow(
            server: server,
            state: host.states[server.id],
            exposureMode: Binding(
                get: {
                    guard let current = model.settings.mcpServers.first(where: { $0.id == server.id })
                    else { return .off }
                    return model.settings.mcpServerExposureMode(for: current)
                },
                set: { setExposureMode($0, for: server) }
            ),
            onReconnect: { host.reconnect(server.id) },
            onEdit: { editing = server },
            onDelete: { pendingDelete = server }
        )
    }

    private func setExposureMode(_ mode: ToolExposureMode, for entry: MCPCatalogEntry) {
        var servers = model.settings.mcpServers
        catalog.setEnabled(
            mode != .off,
            for: entry,
            in: &servers
        )
        var settings = model.settings
        settings.mcpServers = servers
        if let server = catalog.configuredServer(for: entry, in: servers) {
            settings.setMCPServerExposureMode(mode, serverID: server.id)
        }
        model.settings = settings
    }

    private func setExposureMode(_ mode: ToolExposureMode, for server: MCPServerConfig) {
        model.settings.setMCPServerExposureMode(mode, serverID: server.id)
    }

    private func delete(_ server: MCPServerConfig) {
        model.settings.mcpServers.removeAll { $0.id == server.id }
        model.settings.removeMCPServerExposureMode(serverID: server.id)
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
    @Binding var exposureMode: ToolExposureMode
    let onReconnect: (() -> Void)?
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    @State private var copiedAuthorizationCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NativStatusDot(tone: statusTone, pulsing: isConnecting)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name.isEmpty ? "Untitled server" : server.name)
                        .nativTextStyle(.rowTitle)
                    Text(statusText)
                        .nativTextStyle(.supporting)
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
                ToolExposureModeControl(
                    mode: $exposureMode,
                    title: server.name.isEmpty ? "Untitled server" : server.name
                )
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
                            .nativTextStyle(.codeEmphasized)
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
                    title: "Choose Repository Access",
                    message: "GitHub authorization is complete. Select which repositories Nativ can use. You can change this later on GitHub.",
                    actionTitle: "Choose repositories",
                    actionIcon: "arrow.up.right",
                    destination: installationURL
                )
                .padding(.leading, 20)
            } else if case .failed(let failure) = state,
                      let details = failure.details,
                      !details.isEmpty {
                MCPConnectionFailureCallout(details: details)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 11)
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
        case .failed(let failure): failure.message.isEmpty ? "Failed to connect" : failure.message
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

private struct MCPConnectionFailureCallout: View {
    let details: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(details)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 650, alignment: .leading)
        .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.16), lineWidth: 1)
        }
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
                    .nativTextStyle(.sectionTitle)

                Text(message)
                    .nativTextStyle(.supporting)
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

    init(server: MCPServerConfig) {
        name = server.name
        command = server.command
        arguments = server.arguments
        environment = server.environment
        isEnabled = server.isEnabled
    }

    // Lenient: the scaffold and pasted standard mcp.json entries may omit name
    // and isEnabled.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
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
    @State private var launchCommandText: String
    @State private var launchCommandError: String?
    @State private var editingJSON = false
    @State private var jsonText = ""
    @State private var jsonError: String?

    init(server: MCPServerConfig, onSave: @escaping (MCPServerConfig) -> Void, onCancel: @escaping () -> Void) {
        _server = State(initialValue: server)
        _launchCommandText = State(
            initialValue: server.command.isEmpty
                ? ""
                : MCPLaunchCommand(
                    executable: server.command,
                    arguments: server.arguments
                ).rendered
        )
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(server.name.isEmpty ? "New MCP Server" : "Edit MCP Server")
                    .nativTextStyle(.sheetTitle)
                Spacer()
                Toggle("Edit as JSON", isOn: $editingJSON)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: editingJSON) { _, isEditingJSON in
                        switchEditorMode(isEditingJSON: isEditingJSON)
                    }
            }

            if editingJSON {
                TextEditor(text: $jsonText)
                    .nativTextStyle(.code)
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .onChange(of: jsonText) { _, _ in
                        validateJSON()
                    }
                if let jsonError {
                    Text(jsonError)
                        .nativTextStyle(.supporting)
                        .foregroundStyle(.red)
                }
            } else {
                field("Name (optional)") {
                    TextField("Derived from the command if left empty", text: $server.name)
                        .textFieldStyle(.roundedBorder)
                }
                field("Launch command") {
                    TextField(
                        "/Applications/Humla.app/Contents/MacOS/humla-mcp",
                        text: $launchCommandText
                    )
                        .nativTextStyle(.code)
                        .textFieldStyle(.roundedBorder)
                    Text("Paste the executable and any arguments on one line. Nativ launches it directly over stdio without invoking a shell.")
                        .nativTextStyle(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let launchCommandError {
                        Text(launchCommandError)
                            .nativTextStyle(.supporting)
                            .foregroundStyle(.red)
                    }
                }
                field("Environment (KEY=VALUE per line)") {
                    TextEditor(text: environmentText)
                        .nativTextStyle(.code)
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
                    if editingJSON {
                        guard applyJSON() else { return }
                    } else {
                        guard applyLaunchCommand() else { return }
                    }
                    onSave(server)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).nativTextStyle(.supportingEmphasized).foregroundStyle(.secondary)
            content()
        }
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

    private var canSave: Bool {
        if editingJSON {
            return decodedJSONServer() != nil
        }
        return (try? MCPLaunchCommand(parsing: launchCommandText)) != nil
    }

    private func switchEditorMode(isEditingJSON: Bool) {
        if isEditingJSON {
            _ = applyLaunchCommand()
            jsonText = server.command.isEmpty ? mcpJSONScaffold : currentJSON()
            validateJSON()
        } else if applyJSON() {
            launchCommandText = MCPLaunchCommand(
                executable: server.command,
                arguments: server.arguments
            ).rendered
        }
    }

    @discardableResult
    private func applyLaunchCommand() -> Bool {
        do {
            let launchCommand = try MCPLaunchCommand(parsing: launchCommandText)
            server.command = launchCommand.executable
            server.arguments = launchCommand.arguments
            if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                server.name = launchCommand.suggestedName
            }
            launchCommandError = nil
            return true
        } catch {
            launchCommandError = error.localizedDescription
            return false
        }
    }

    private func currentJSON() -> String {
        let payload = MCPServerJSON(server: server)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private func validateJSON() {
        if decodedJSONServer() == nil {
            jsonError = "Enter a valid Nativ MCP server JSON object."
        } else {
            jsonError = nil
        }
    }

    @discardableResult
    private func applyJSON() -> Bool {
        guard let decoded = decodedJSONServer() else {
            validateJSON()
            return false
        }
        server = decoded
        jsonError = nil
        return true
    }

    private func decodedJSONServer() -> MCPServerConfig? {
        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MCPServerJSON.self, from: data),
              !payload.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        var decoded = server
        decoded.name = payload.name
        decoded.command = payload.command
        decoded.arguments = payload.arguments
        decoded.environment = payload.environment
        decoded.isEnabled = payload.isEnabled
        if decoded.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decoded.name = MCPLaunchCommand(executable: decoded.command).suggestedName
        }
        return decoded
    }
}
