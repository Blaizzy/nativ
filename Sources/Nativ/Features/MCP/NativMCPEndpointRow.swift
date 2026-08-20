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
                Text("MCP Server")
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
            NativMCPEndpointDetails(preferences: preferences, state: state)
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
            return "Listening on \(port) · \(count == 1 ? "1 app" : "\(count) apps")"
        }
    }
}

struct NativMCPEndpointDetails: View {
    @ObservedObject var preferences: NativMCPPreferences
    let state: NativMCPState
    @Environment(\.dismiss) private var dismiss
    @State private var funnel = NativFunnelStatus()
    @State private var funnelError: String?
    @State private var isChangingFunnel = false
    @State private var isAddingApp = false
    @State private var newAppName = ""
    @State private var newAppScope: NativMCPScope = .readOnly

    private static let labelWidth: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 16)
            portRow
            Divider().padding(.vertical, 16)
            internetRow
            Divider().padding(.vertical, 16)
            appsSection
            footer
        }
        .padding(24)
        .frame(width: 560)
        .task(id: preferences.port) {
            await refreshFunnel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP server")
                .font(.title3.weight(.semibold))
            Text("Let other apps list and run Nativ's tools without opening a chat.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var portRow: some View {
        HStack(spacing: 12) {
            Text("Local port")
                .frame(width: Self.labelWidth, alignment: .leading)

            TextField("", value: $preferences.port, format: .number.grouping(.never))
                .font(.body.monospacedDigit())
                .frame(width: 90)

            switch state {
            case .serving:
                Text("listening")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .off:
                Text("off")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var internetRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Internet access")
                    .frame(width: Self.labelWidth, alignment: .leading)

                if funnel.isInstalled {
                    Button(funnel.isServing ? "Turn Off" : "Turn On") {
                        changeFunnel {
                            let integration = NativFunnelIntegration(port: preferences.port)
                            return funnel.isServing
                                ? await integration.disable()
                                : await integration.enable()
                        }
                    }
                    .controlSize(.small)
                    .disabled(isChangingFunnel)
                } else {
                    Link("Install Tailscale", destination: NativFunnelIntegration.downloadURL)
                        .font(.callout)
                }

                if isChangingFunnel {
                    ProgressView()
                        .controlSize(.small)
                } else if funnel.isServing {
                    badge("reachable publicly", tint: .orange)
                } else if funnel.isInstalled {
                    Text("off")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let publicURL {
                copyField(publicURL, help: "Copy this address")
            }

            if let funnelError {
                Text(funnelError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected apps")
                        .font(.callout.weight(.semibold))
                    Text("Each app gets its own key. Give cloud services read-only keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isAddingApp = true
                } label: {
                    Label("Add app", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(isAddingApp)
            }

            ForEach(preferences.agents) { agent in
                Divider()
                appRow(agent)
            }

            if isAddingApp {
                Divider()
                addAppRow
            }
        }
    }

    private func appRow(_ agent: NativMCPAgent) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.callout.weight(.medium))
                Text(NativMCPKey.masked(preferences.secret(for: agent.id) ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            badge(agent.scope.title, tint: agent.scope == .full ? .orange : .secondary)

            Button {
                copy(configuration(for: agent))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy this app's configuration, including its key")

            Button {
                preferences.removeAgent(agent.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(preferences.agents.count == 1)
            .help("Remove this app and revoke its key")
        }
    }

    private var addAppRow: some View {
        HStack(spacing: 8) {
            TextField("App name", text: $newAppName)
                .frame(width: 180)

            Picker("", selection: $newAppScope) {
                ForEach(NativMCPScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Spacer()

            Button("Cancel") {
                isAddingApp = false
                newAppName = ""
            }
            .controlSize(.small)

            Button("Add") {
                preferences.addAgent(name: newAppName, scope: newAppScope)
                newAppName = ""
                isAddingApp = false
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 20)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }

    private func copyField(_ value: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            Button {
                copy(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var publicURL: String? {
        guard funnel.isServing, let host = funnel.publicHost else {
            return nil
        }
        return "https://\(host)/mcp"
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
