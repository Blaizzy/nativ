import SwiftUI

struct NativMCPEndpointRow: View {
    @ObservedObject var preferences: NativMCPPreferences
    let state: NativMCPState
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(iconTint)

            VStack(alignment: .leading, spacing: 2) {
                Text("External Plugin")
                    .font(.callout.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Details") {
                isShowingDetails = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle("", isOn: $preferences.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .sheet(isPresented: $isShowingDetails) {
            NativMCPEndpointDetails(preferences: preferences)
        }
    }

    private var iconTint: Color {
        switch state {
        case .off:
            .secondary
        case .serving:
            .accentColor
        case .failed:
            .orange
        }
    }

    private var statusText: String {
        switch state {
        case .off:
            return "Off. Other apps cannot reach Nativ's tools."
        case .failed(let message):
            return message
        case .serving(let port):
            let count = preferences.agents.count
            let agents = count == 1 ? "1 agent" : "\(count) agents"
            return "Listening on port \(port) · \(agents)"
        }
    }
}

struct NativMCPEndpointDetails: View {
    @ObservedObject var preferences: NativMCPPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyName = ""
    @State private var newKeyScope: NativMCPScope = .readOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("External Plugin")
                .font(.headline)

            Text("Other apps can list and run Nativ's tools without opening a chat. Nativ only ever listens on this Mac; a cloud service needs you to forward a public address to this port.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LabeledContent("Port") {
                TextField("", value: $preferences.port, format: .number)
                    .frame(width: 90)
            }

            LabeledContent("Public address") {
                TextField("optional", text: $preferences.publicHost)
                    .frame(width: 260)
            }

            Divider()

            Text("Connected apps")
                .font(.callout.weight(.medium))

            ForEach(preferences.agents) { agent in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                            .font(.callout)
                        Text(agent.scope.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Copy Config") {
                        copy(configuration(for: agent))
                    }
                    .controlSize(.small)

                    Button("Remove") {
                        preferences.removeAgent(agent.id)
                    }
                    .controlSize(.small)
                    .disabled(preferences.agents.count == 1)
                }
            }

            HStack(spacing: 8) {
                TextField("New app", text: $newKeyName)
                    .frame(width: 160)

                Picker("", selection: $newKeyScope) {
                    ForEach(NativMCPScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Button("Add") {
                    preferences.addAgent(name: newKeyName, scope: newKeyScope)
                    newKeyName = ""
                }
                .controlSize(.small)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func configuration(for agent: NativMCPAgent) -> String {
        let host = preferences.publicHost.trimmingCharacters(in: .whitespaces)
        let url = agent.scope == .readOnly && !host.isEmpty
            ? "https://\(host)/mcp"
            : "http://127.0.0.1:\(preferences.port)/mcp"
        return """
        {
          "mcpServers": {
            "nativ": {
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(preferences.secret(for: agent.id) ?? "")" }
            }
          }
        }
        """
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
