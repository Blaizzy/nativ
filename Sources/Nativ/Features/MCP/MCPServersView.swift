import NativServerKit
import SwiftUI

struct MCPServersPanel: View {
    @ObservedObject var host: MCPHostManager
    @Binding var servers: [MCPServerConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Servers")
                        .font(.headline)
                    Text("Connect Model Context Protocol servers to give chat models extra tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    servers.append(MCPServerConfig(name: "New Server", isEnabled: false))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if servers.isEmpty {
                Text("No servers configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach($servers) { $server in
                    MCPServerRow(server: $server, state: host.states[server.id]) {
                        servers.removeAll { $0.id == server.id }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }
}

private struct MCPServerRow: View {
    @Binding var server: MCPServerConfig
    let state: MCPServerConnectionState?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $server.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                TextField("Name", text: $server.name)
                    .textFieldStyle(.roundedBorder)
                statusBadge
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            TextField("Command (for example, npx)", text: $server.command)
                .textFieldStyle(.roundedBorder)
            TextField("Arguments (one per line)", text: argumentsText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            TextField("Environment (KEY=VALUE per line)", text: environmentText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.05)))
    }

    private var argumentsText: Binding<String> {
        Binding(
            get: { server.arguments.joined(separator: "\n") },
            set: { server.arguments = $0.split(whereSeparator: \.isNewline).map(String.init) }
        )
    }

    private var environmentText: Binding<String> {
        Binding(
            get: {
                server.environment
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "\n")
            },
            set: { text in
                var parsed: [String: String] = [:]
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let separator = line.firstIndex(of: "=") else { continue }
                    let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    parsed[key] = String(line[line.index(after: separator)...])
                }
                server.environment = parsed
            }
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .connected(let toolCount):
            badge(toolCount == 1 ? "1 tool" : "\(toolCount) tools", color: .green)
        case .connecting:
            badge("Connecting…", color: .secondary)
        case .failed(let message):
            badge("Error", color: .red)
                .help(message)
        case .disabled, nil:
            badge("Off", color: .secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
