import NativServerKit
import SwiftUI

struct MCPServersPanel: View {
    @ObservedObject var host: MCPHostManager
    @Binding var servers: [MCPServerConfig]
    @Binding var disabledToolNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your servers")
                        .font(.headline)
                    Text("Enable a server to load its tools. Tools are used by tool-capable models.")
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
                emptyState
            } else {
                ForEach($servers) { $server in
                    MCPServerRow(
                        server: $server,
                        state: host.states[server.id],
                        tools: host.tools(forServer: server.id),
                        disabledToolNames: $disabledToolNames,
                        onRemove: { servers.removeAll { $0.id == server.id } },
                        onReconnect: { host.reconnect(server.id) }
                    )
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No servers yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add one from the catalog on the right, or “Add” a custom server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct MCPServerRow: View {
    @Binding var server: MCPServerConfig
    let state: MCPServerConnectionState?
    let tools: [(name: String, displayName: String)]
    @Binding var disabledToolNames: [String]
    let onRemove: () -> Void
    let onReconnect: () -> Void

    private let chipColumns = [GridItem(.adaptive(minimum: 96, maximum: 220), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $server.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                TextField("Name", text: $server.name)
                    .textFieldStyle(.roundedBorder)
                statusBadge
                if isFailed {
                    Button(action: onReconnect) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reconnect")
                }
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

            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !tools.isEmpty {
                LazyVGrid(columns: chipColumns, alignment: .leading, spacing: 6) {
                    ForEach(tools, id: \.name) { tool in
                        toolChip(name: tool.name, displayName: tool.displayName)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.05)))
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func toolChip(name: String, displayName: String) -> some View {
        let isOn = !disabledToolNames.contains(name)
        return Button {
            if isOn {
                disabledToolNames.append(name)
            } else {
                disabledToolNames.removeAll { $0 == name }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill((isOn ? Color.accentColor : Color.secondary).opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Enabled — click to disable" : "Disabled — click to enable")
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
        case .failed:
            badge("Error", color: .red)
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
