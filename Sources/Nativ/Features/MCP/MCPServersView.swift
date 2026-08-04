import NativServerKit
import SwiftUI

struct MCPServersView: View {
    @ObservedObject var model: NativModel
    @ObservedObject private var manager: MCPServerManager
    var titleLeadingInset: CGFloat = 0
    @State private var isPresentingAddServer = false

    init(model: NativModel, titleLeadingInset: CGFloat = 0) {
        self.model = model
        self.manager = model.mcpServers
        self.titleLeadingInset = titleLeadingInset
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nativMainContentBackground)
        .sheet(isPresented: $isPresentingAddServer) {
            MCPAddServerSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Servers")
                    .font(.title2.weight(.semibold))
                Text("Connect Nativ's chat to Model Context Protocol servers. Nothing runs until you add and start one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isPresentingAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
        }
        .padding(.horizontal, 28)
        .padding(.leading, titleLeadingInset)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if manager.connections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No MCP servers configured")
                    .font(.headline)
                Text("Add a server to let chat use its tools.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(manager.connections) { connection in
                    MCPServerRow(connection: connection, model: model)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct MCPServerRow: View {
    @ObservedObject var connection: MCPServerConnection
    let model: NativModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.configuration.name)
                    .font(.body.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButton
            Button {
                model.removeMCPServer(connection.configuration.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this server")
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch connection.state {
        case .stopped:
            .secondary
        case .starting:
            .yellow
        case .running:
            .green
        case .crashed:
            .red
        }
    }

    private var statusText: String {
        switch connection.state {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting…"
        case .running(let toolCount):
            "Running · \(toolCount) tool\(toolCount == 1 ? "" : "s")"
        case .crashed:
            connection.lastError.map { "Failed to start: \($0)" } ?? "Failed to start"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch connection.state {
        case .stopped, .crashed:
            Button("Start") {
                model.startMCPServer(connection.configuration.id)
            }
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .running:
            Button("Stop") {
                model.stopMCPServer(connection.configuration.id)
            }
        }
    }
}

private struct MCPAddServerSheet: View {
    let model: NativModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var consentExemptToolsText = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name)
                if !name.isEmpty, !MCPToolNameQualifier.isValidServerName(name) {
                    Text("Name can't be empty or contain \"__\".")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField("Command", text: $command, prompt: Text("npx"))
                TextField("Arguments (space-separated)", text: $argumentsText, prompt: Text("-y @modelcontextprotocol/server-filesystem /path/to/folder"))
            }
            Section("Environment (optional, one KEY=VALUE per line)") {
                TextEditor(text: $environmentText)
                    .frame(minHeight: 60)
                    .font(.system(.body, design: .monospaced))
            }
            Section("Tools that don't need approval (optional, comma-separated)") {
                TextField("read_file, list_directory", text: $consentExemptToolsText)
                Text("Every other tool on this server will ask for confirmation before it runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    model.addMCPServer(makeConfiguration())
                    dismiss()
                }
                .disabled(!canSubmit)
            }
        }
    }

    private var canSubmit: Bool {
        MCPToolNameQualifier.isValidServerName(name)
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeConfiguration() -> MCPServerConfiguration {
        let arguments = argumentsText
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        var environment: [String: String] = [:]
        for line in environmentText.split(separator: "\n") {
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            environment[key] = value
        }
        let consentExemptTools = Set(
            consentExemptToolsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        return MCPServerConfiguration(
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            arguments: arguments,
            environment: environment,
            consentExemptTools: consentExemptTools
        )
    }
}
