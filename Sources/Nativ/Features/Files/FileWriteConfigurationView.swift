import AppKit
import SwiftUI

extension Notification.Name {
    static let fileWriteConfigurationDidChange = Notification.Name(
        "dev.local.Nativ.file-write-configuration-did-change"
    )
}

struct FileWriteConfigurationView: View {
    var model: NativModel
    let onConfigurationChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var configuredRootURL: URL? {
        FileWriteAccessPolicy.configuredRootURL(rootPath: model.settings.fileWriteRootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Write")
                        .font(.title2.weight(.semibold))
                    Text("Choose the folder where standalone chats may create and edit files.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(configuredRootURL?.path ?? "No folder selected")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(configuredRootURL == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(
                        configuredRootURL == nil
                            ? "File editing remains unavailable in standalone chats until a folder is selected. Project chats use their project folder."
                            : "File editing is confined to this folder. Protected instruction and credential configuration files still require confirmation."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button(configuredRootURL == nil ? "Choose Folder…" : "Replace Folder…") {
                            chooseFolder()
                        }
                        if configuredRootURL != nil {
                            Button("Remove", role: .destructive) { updateRoot(nil) }
                        }
                    }
                }
                .padding(4)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(22)
        .frame(width: 560, height: 320)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Allow Writing"
        panel.message = "Choose the folder that Nativ's File Write tools may modify."
        panel.directoryURL = configuredRootURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileWriteAccessPolicy.isConfigured(rootPath: resolved.path) else {
            errorMessage = "That folder is not writable."
            return
        }
        updateRoot(resolved.path)
    }

    private func updateRoot(_ path: String?) {
        errorMessage = nil
        model.settings.fileWriteRootPath = path
        let configured = FileWriteAccessPolicy.isConfigured(rootPath: path)
        NotificationCenter.default.post(name: .fileWriteConfigurationDidChange, object: nil)
        onConfigurationChanged(configured)
    }
}
