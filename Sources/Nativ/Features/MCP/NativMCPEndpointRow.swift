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
            return "Off. Coding agents on this Mac cannot reach Nativ."
        }
        if preferences.outsideIsEnabled {
            return "Listening on port \(preferences.localPort), and on \(preferences.outsidePort) for agents outside this Mac"
        }
        return "Listening on port \(preferences.localPort) for agents on this Mac"
    }
}

struct NativMCPEndpointDetails: View {
    @ObservedObject var preferences: NativMCPPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Access")
                .font(.headline)

            Text("Coding agents can list and run Nativ's tools without opening a chat.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            LabeledContent("Port") {
                TextField("", value: $preferences.localPort, format: .number)
                    .frame(width: 90)
            }

            LabeledContent("Key") {
                HStack(spacing: 6) {
                    Text(preferences.localSecret.prefix(8) + "…")
                        .font(.callout.monospaced())
                    Button("Copy") {
                        copy(preferences.localSecret)
                    }
                    .controlSize(.small)
                }
            }

            Button("Copy Client Configuration") {
                copy(clientConfiguration)
            }
            .controlSize(.small)

            Divider()

            Toggle("Allow agents outside this Mac", isOn: $preferences.outsideIsEnabled)

            if preferences.outsideIsEnabled {
                Text("Nativ still only listens on this Mac. To let a cloud agent in, forward a public address to port \(preferences.outsidePort) yourself, then paste that address here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Outside port") {
                    TextField("", value: $preferences.outsidePort, format: .number)
                        .frame(width: 90)
                }

                LabeledContent("Public address") {
                    TextField("name.tail-scale.ts.net", text: $preferences.publicHost)
                        .frame(width: 260)
                }

                LabeledContent("Outside key") {
                    Button("Copy") {
                        copy(preferences.outsideSecret)
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Button("Replace Keys") {
                    preferences.regenerateSecrets()
                }
                .controlSize(.small)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var clientConfiguration: String {
        """
        {
          "mcpServers": {
            "nativ": {
              "url": "http://127.0.0.1:\(preferences.localPort)/mcp",
              "headers": { "Authorization": "Bearer \(preferences.localSecret)" }
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
