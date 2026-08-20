import SwiftUI

struct NativMCPEndpointRow: View {
    @ObservedObject var preferences: NativMCPPreferences
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(preferences.isEnabled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Access")
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

    private var statusText: String {
        guard preferences.isEnabled else {
            return "Off. Coding agents cannot reach Nativ."
        }
        let count = preferences.keys.count
        let keys = count == 1 ? "1 key" : "\(count) keys"
        return "Listening on port \(preferences.port) · \(keys)"
    }
}

struct NativMCPEndpointDetails: View {
    @ObservedObject var preferences: NativMCPPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyName = ""
    @State private var newKeyScope: NativMCPScope = .readOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Access")
                .font(.headline)

            Text("Coding agents can list and run Nativ's tools without opening a chat. Nativ only ever listens on this Mac; a cloud agent needs you to forward a public address to this port.")
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

            Text("Keys")
                .font(.callout.weight(.medium))

            ForEach(preferences.keys) { key in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.name)
                            .font(.callout)
                        Text(key.scope.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Copy Config") {
                        copy(configuration(for: key))
                    }
                    .controlSize(.small)

                    Button("Replace") {
                        preferences.replaceSecret(for: key.id)
                    }
                    .controlSize(.small)

                    Button("Remove") {
                        preferences.removeKey(key.id)
                    }
                    .controlSize(.small)
                    .disabled(preferences.keys.count == 1)
                }
            }

            HStack(spacing: 8) {
                TextField("New agent", text: $newKeyName)
                    .frame(width: 160)

                Picker("", selection: $newKeyScope) {
                    ForEach(NativMCPScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Button("Add") {
                    preferences.addKey(name: newKeyName, scope: newKeyScope)
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

    private func configuration(for key: NativMCPKey) -> String {
        let host = preferences.publicHost.trimmingCharacters(in: .whitespaces)
        let url = host.isEmpty
            ? "http://127.0.0.1:\(preferences.port)/mcp"
            : "https://\(host)/mcp"
        return """
        {
          "mcpServers": {
            "nativ": {
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(key.secret)" }
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
