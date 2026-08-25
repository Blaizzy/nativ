import AppKit
import SwiftUI

extension Notification.Name {
    static let fileReadConfigurationDidChange = Notification.Name(
        "dev.local.Nativ.file-read-configuration-did-change"
    )
}

struct FileReadConfigurationView: View {
    var model: NativModel
    let onConfigurationChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var configuredRootURL: URL? {
        FileReadAccessPolicy.configuredRootURL(
            rootPath: model.settings.fileReadRootPath
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Read")
                        .font(.title2.weight(.semibold))
                    Text("Choose the folder where Nativ tools may read and search.")
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
                            ? "The read_file and search_files tools remain unavailable until a folder is selected."
                            : "Relative paths resolve inside this folder. Absolute paths and symlinks cannot escape it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button(configuredRootURL == nil ? "Choose Folder…" : "Replace Folder…") {
                            chooseFolder()
                        }
                        if configuredRootURL != nil {
                            Button("Remove", role: .destructive) {
                                updateRoot(nil)
                            }
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
        .frame(width: 520, height: 300)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Allow Reading"
        panel.message = "Choose the folder that Nativ's File Read tools may access."
        panel.directoryURL = configuredRootURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileReadAccessPolicy.isConfigured(rootPath: resolved.path) else {
            errorMessage = "That folder is not readable."
            return
        }
        updateRoot(resolved.path)
    }

    private func updateRoot(_ path: String?) {
        errorMessage = nil
        model.settings.fileReadRootPath = path
        let configured = FileReadAccessPolicy.isConfigured(rootPath: path)
        NotificationCenter.default.post(name: .fileReadConfigurationDidChange, object: nil)
        onConfigurationChanged(configured)
    }
}
