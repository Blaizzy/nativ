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
    @State private var funnel = NativFunnelStatus()
    @State private var isChangingFunnel = false
    @State private var funnelError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("External Plugin")
                .font(.headline)

            Text("Other apps can list and run Nativ's tools without opening a chat. Nativ only listens on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Port") {
                TextField("", value: $preferences.port, format: .number.grouping(.never))
                    .frame(width: 90)
            }

            internetAccess

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
        .padding(24)
        .frame(width: 580)
    }

    @ViewBuilder
    private var internetAccess: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Reachable from the internet")
                    .font(.callout)

                Spacer()

                if funnel.isServing {
                    Button("Turn Off") {
                        changeFunnel { await NativFunnelIntegration(port: preferences.port).disable() }
                    }
                    .controlSize(.small)
                    .disabled(isChangingFunnel)
                } else if funnel.isInstalled {
                    Button("Turn On") {
                        changeFunnel { await NativFunnelIntegration(port: preferences.port).enable() }
                    }
                    .controlSize(.small)
                    .disabled(isChangingFunnel)
                } else {
                    Link("Install Tailscale", destination: NativFunnelIntegration.downloadURL)
                        .font(.callout)
                }
            }

            if let publicURL, funnelError == nil {
                Button {
                    copy(publicURL)
                } label: {
                    HStack(spacing: 5) {
                        Text(publicURL)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Copy this address")
            }

            Text(funnelError ?? internetAccessDetail)
                .font(.caption)
                .foregroundStyle(funnelError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: preferences.port) {
            await refreshFunnel()
        }
    }

    private var publicURL: String? {
        guard funnel.isServing, let host = funnel.publicHost else {
            return nil
        }
        return "https://\(host)/mcp"
    }

    private var internetAccessDetail: String {
        if publicURL != nil {
            return "Give a cloud service a read-only key, never a full one."
        }
        if funnel.isInstalled {
            return "Off. Apps on this Mac work without it. Turn it on only to let a cloud service in through Tailscale."
        }
        return "Off. Apps on this Mac work without it. Letting a cloud service in needs Tailscale."
    }

    private func changeFunnel(_ change: @escaping () async -> String?) {
        isChangingFunnel = true
        funnelError = nil
        Task {
            funnelError = await change()
            await refreshFunnel()
            isChangingFunnel = false
        }
    }

    private func refreshFunnel() async {
        funnel = await NativFunnelIntegration(port: preferences.port).status()
    }

    private func configuration(for agent: NativMCPAgent) -> String {
        let url: String
        if agent.scope == .readOnly, funnel.isServing, let host = funnel.publicHost {
            url = "https://\(host)/mcp"
        } else {
            url = "http://127.0.0.1:\(preferences.port)/mcp"
        }
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
