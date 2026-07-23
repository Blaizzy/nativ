import AppKit
import Combine
import SwiftUI

extension IntegrationModelDescriptor {
    init(localModel: LocalModel) {
        self.init(
            id: localModel.repoID,
            displayName: localModel.repoID.split(separator: "/").last.map(String.init) ?? localModel.repoID,
            contextWindow: localModel.contextSize,
            supportsVision: localModel.capabilities.contains(.vision),
            supportsReasoning: localModel.capabilities.contains(.reasoning),
            supportsTools: localModel.capabilities.contains(.tools)
        )
    }
}

@MainActor
final class IntegrationsViewModel: ObservableObject {
    @Published var selectedTool: IntegrationTool?
    @Published var selectedModelID: String?
    @Published private(set) var statuses = Dictionary(
        uniqueKeysWithValues: IntegrationTool.allCases.map { ($0, IntegrationToolStatus.unavailable) }
    )
    @Published private(set) var isRefreshingStatuses = false
    @Published private(set) var activeOperation: IntegrationTool?
    @Published var errorMessage: String?

    let library = LocalModelLibrary()
    private let serverModel: NativModel
    private let defaults = UserDefaults.standard
    private var libraryObservation: AnyCancellable?

    init(serverModel: NativModel) {
        self.serverModel = serverModel
        libraryObservation = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var eligibleModels: [IntegrationModelDescriptor] {
        library.models
            .filter {
                ($0.capabilities.contains(.text) || $0.capabilities.contains(.vision))
                    && !$0.capabilities.contains(.imageGeneration)
                    && !$0.capabilities.contains(.embeddings)
            }
            .map(IntegrationModelDescriptor.init)
    }

    var loadedModelID: String? {
        serverModel.metrics?.server.loadedModel ?? serverModel.settings.normalized().languageModelID
    }

    var selectedModel: IntegrationModelDescriptor? {
        guard let selectedModelID else { return nil }
        return eligibleModels.first { $0.id == selectedModelID }
    }

    var isBusy: Bool { activeOperation != nil }

    var integrationEndpoint: String {
        profiles.openAIBaseURL
    }

    private var integrationServerBaseURL: URL {
        guard let activeServerPort = serverModel.activeServerPort else {
            return serverModel.settings.serverBaseURL
        }
        return URL(string: "http://127.0.0.1:\(activeServerPort)")!
    }

    private var profiles: IntegrationProfileManager {
        IntegrationProfileManager(serverBaseURL: integrationServerBaseURL)
    }

    func appear() {
        library.scan(path: serverModel.settings.modelSearchPath)
        refreshStatuses()
    }

    func modelsDidChange() {
        library.scan(path: serverModel.settings.modelSearchPath)
    }

    func select(_ tool: IntegrationTool) {
        selectedTool = tool
        resolveSelectedModel()
    }

    func resolveSelectedModel() {
        guard !eligibleModels.isEmpty else {
            selectedModelID = nil
            return
        }
        if let selectedModelID, eligibleModels.contains(where: { $0.id == selectedModelID }) {
            return
        }
        if let loadedModelID, eligibleModels.contains(where: { $0.id == loadedModelID }) {
            selectedModelID = loadedModelID
        } else {
            selectedModelID = eligibleModels.first?.id
        }
    }

    func refreshStatuses() {
        guard !isRefreshingStatuses else { return }
        isRefreshingStatuses = true
        Task {
            var refreshed: [IntegrationTool: IntegrationToolStatus] = [:]
            for tool in IntegrationTool.allCases {
                refreshed[tool] = await profiles.status(for: tool)
            }
            statuses = refreshed
            isRefreshingStatuses = false
        }
    }

    func configure(_ tool: IntegrationTool) {
        guard let selectedModelID else {
            errorMessage = IntegrationServiceError.noModel.localizedDescription
            return
        }
        activeOperation = tool
        do {
            try configureProfile(tool: tool, selectedModelID: selectedModelID)
            var status = statuses[tool] ?? .unavailable
            status.isConfigured = true
            statuses[tool] = status
        } catch {
            errorMessage = error.localizedDescription
        }
        activeOperation = nil
    }

    func configureAndOpen(_ tool: IntegrationTool, workingDirectory: URL) {
        guard let selectedModelID else {
            errorMessage = IntegrationServiceError.noModel.localizedDescription
            return
        }
        guard let executableURL = statuses[tool]?.executableURL else {
            errorMessage = IntegrationServiceError.missingExecutable(tool).localizedDescription
            return
        }

        rememberWorkingDirectory(workingDirectory, for: tool)
        activeOperation = tool
        Task {
            do {
                try configureProfile(tool: tool, selectedModelID: selectedModelID)
                var status = statuses[tool] ?? .unavailable
                status.isConfigured = true
                statuses[tool] = status

                try await prepareServer(modelID: selectedModelID)
                try profiles.launch(
                    tool: tool,
                    executableURL: executableURL,
                    selectedModelID: selectedModelID,
                    workingDirectory: workingDirectory
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            activeOperation = nil
        }
    }

    func workingDirectory(for tool: IntegrationTool) -> URL? {
        guard let path = defaults.string(forKey: workingDirectoryKey(for: tool)) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func rememberWorkingDirectory(_ url: URL, for tool: IntegrationTool) {
        defaults.set(url.path, forKey: workingDirectoryKey(for: tool))
        objectWillChange.send()
    }

    func revealConfiguration(for tool: IntegrationTool) {
        let url = profiles.configurationURL(for: tool)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func launchCommand(for tool: IntegrationTool, workingDirectory: URL) -> String? {
        guard let selectedModelID, let executableURL = statuses[tool]?.executableURL else {
            return nil
        }
        return profiles.launchCommand(
            tool: tool,
            executableURL: executableURL,
            selectedModelID: selectedModelID,
            workingDirectory: workingDirectory
        )
    }

    func copyLaunchCommand(for tool: IntegrationTool, workingDirectory: URL) {
        guard let command = launchCommand(for: tool, workingDirectory: workingDirectory) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func configureProfile(tool: IntegrationTool, selectedModelID: String) throws {
        try profiles.configure(
            tool: tool,
            selectedModelID: selectedModelID,
            models: eligibleModels,
            maxOutputTokens: serverModel.settings.normalized().maxTokens
        )
    }

    private func prepareServer(modelID: String) async throws {
        // Keep the process alive and hot-swap its text-generation cache through
        // the management endpoint. The harness also sends this model on every
        // inference request, so subsequent responses stay on the selection.
        // Check the listener before starting a process because an earlier app
        // session may still own the bundled server on the configured port.
        if await inferenceEndpointIsReady() {
            try await loadModelThroughEndpoint(modelID)
            return
        }

        if !serverModel.isRunning {
            serverModel.startServer()
        }

        let deadline = Date().addingTimeInterval(300)
        var stoppedPolls = 0
        while Date() < deadline {
            if await inferenceEndpointIsReady() {
                try await loadModelThroughEndpoint(modelID)
                return
            }

            if serverModel.isRunning {
                stoppedPolls = 0
            } else {
                stoppedPolls += 1
                if stoppedPolls >= 10 {
                    throw IntegrationServiceError.serverUnavailable
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw IntegrationServiceError.serverUnavailable
    }

    private func inferenceEndpointIsReady() async -> Bool {
        do {
            // /v1/models is part of the public inference API and does not
            // require a management API key. It also proves the listener that
            // the harness will use is ready.
            var request = URLRequest(url: integrationServerBaseURL.appendingPathComponent("v1/models"))
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func loadModelThroughEndpoint(_ modelID: String) async throws {
        var request = URLRequest(url: integrationServerBaseURL.appendingPathComponent("v1/models/load"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IntegrationServiceError.modelLoadFailed(modelID, "The server returned an invalid response.")
            }
            if (200..<300).contains(http.statusCode) {
                return
            }

            // Older bundled servers do not expose the management endpoint.
            // Every harness request still includes the selected model, so the
            // inference server will load it on demand and stream the response.
            if http.statusCode == 404 {
                return
            }

            throw IntegrationServiceError.modelLoadFailed(
                modelID,
                serverErrorMessage(from: data) ?? "The server returned HTTP \(http.statusCode)."
            )
        } catch let error as IntegrationServiceError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw IntegrationServiceError.modelLoadTimedOut(modelID)
        } catch {
            throw IntegrationServiceError.modelLoadFailed(modelID, error.localizedDescription)
        }
    }

    private func serverErrorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String,
           !detail.isEmpty {
            return detail
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private func workingDirectoryKey(for tool: IntegrationTool) -> String {
        "integration.\(tool.rawValue).workingDirectory"
    }
}

struct IntegrationsView: View {
    @StateObject private var viewModel: IntegrationsViewModel

    init(model: NativModel) {
        _viewModel = StateObject(wrappedValue: IntegrationsViewModel(serverModel: model))
    }

    var body: some View {
        Group {
            if let selectedTool = viewModel.selectedTool {
                IntegrationDetailView(tool: selectedTool, viewModel: viewModel)
            } else {
                IntegrationCatalogView(viewModel: viewModel)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: viewModel.appear)
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            viewModel.modelsDidChange()
        }
        .onChange(of: viewModel.library.models) { _, _ in
            viewModel.resolveSelectedModel()
        }
        .alert("Integration Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }
}

private struct IntegrationCatalogView: View {
    @ObservedObject var viewModel: IntegrationsViewModel
    private let columns = [
        GridItem(.adaptive(minimum: 245, maximum: 330), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Integrations")
                        .font(.title2.weight(.semibold))
                    Text("Run your coding tools with models served from this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.refreshStatuses()
                } label: {
                    if viewModel.isRefreshingStatuses {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRefreshingStatuses)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(IntegrationTool.allCases) { tool in
                        IntegrationCard(
                            tool: tool,
                            status: viewModel.statuses[tool] ?? .unavailable,
                            isLoading: viewModel.isRefreshingStatuses
                        ) {
                            viewModel.select(tool)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct IntegrationCard: View {
    let tool: IntegrationTool
    let status: IntegrationToolStatus
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    IntegrationLogo(tool: tool, size: 52)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(tool.displayName)
                        .font(.title3.bold())
                    Text(tool.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else if status.executableURL == nil {
                        Image(systemName: "arrow.down.circle")
                        Text("Not installed")
                    } else if status.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Configured")
                    } else {
                        Image(systemName: "gearshape")
                        Text("Ready to configure")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 175, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isHovering ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Configure \(tool.displayName)")
    }
}

private struct IntegrationDetailView: View {
    let tool: IntegrationTool
    @ObservedObject var viewModel: IntegrationsViewModel
    @State private var workingDirectory: URL?

    private var status: IntegrationToolStatus {
        viewModel.statuses[tool] ?? .unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    viewModel.selectedTool = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("All integrations")

                IntegrationLogo(tool: tool, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.displayName).font(.title2.bold())
                    Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                IntegrationAvailabilityBadge(status: status)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if status.executableURL == nil, !viewModel.isRefreshingStatuses {
                        missingToolPanel
                    } else {
                        modelPanel
                        projectPanel
                        launchCommandPanel
                        configurationPanel
                        actionBar
                    }
                }
                .frame(maxWidth: 760)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            workingDirectory = viewModel.workingDirectory(for: tool)
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private var missingToolPanel: some View {
        IntegrationPanel(title: "Installation required", systemImage: "arrow.down.app") {
            Text("Install \(tool.displayName), then return here and refresh its status.")
                .foregroundStyle(.secondary)
            HStack {
                Button("View installation guide") {
                    NSWorkspace.shared.open(tool.installURL)
                }
                .buttonStyle(.borderedProminent)
                Button("Check again") {
                    viewModel.refreshStatuses()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var modelPanel: some View {
        IntegrationPanel(title: "Model", systemImage: "cube.transparent") {
            if viewModel.library.isScanning && viewModel.eligibleModels.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Scanning installed models…").foregroundStyle(.secondary)
                }
            } else if viewModel.eligibleModels.isEmpty {
                Text("No installed chat models were found. Download one from the Models page first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $viewModel.selectedModelID) {
                    ForEach(viewModel.eligibleModels) { model in
                        Text(model.id).tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if let selected = viewModel.selectedModel {
                    HStack(spacing: 8) {
                        if selected.id == viewModel.loadedModelID {
                            IntegrationPill(title: "Loaded", systemImage: "bolt.fill", color: .green)
                        }
                        if let context = selected.contextWindow {
                            IntegrationPill(title: formatContext(context), systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        if selected.supportsVision {
                            IntegrationPill(title: "Vision", systemImage: "eye")
                        }
                        if selected.supportsReasoning {
                            IntegrationPill(title: "Reasoning", systemImage: "brain")
                        }
                    }
                    if !selected.supportsTools {
                        Label(
                            "Tool calling was not detected for this model. The integration can open, but coding actions may fail.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var projectPanel: some View {
        IntegrationPanel(title: "Project folder", systemImage: "folder") {
            HStack(spacing: 10) {
                Text(workingDirectory?.path ?? "Choose a folder")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFolder)
                    .buttonStyle(.bordered)
            }
            Text("\(tool.displayName) opens in this folder. The last folder is remembered for this tool.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configurationPanel: some View {
        IntegrationPanel(title: "Managed configuration", systemImage: "gearshape.2") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                IntegrationConfigurationRow(label: "Endpoint", value: viewModel.integrationEndpoint)
                IntegrationConfigurationRow(label: "Profile", value: IntegrationProfileManager.providerID)
                IntegrationConfigurationRow(label: "Model loading", value: "On demand · no restart")
                IntegrationConfigurationRow(label: "Responses", value: "Streaming")
                if let version = status.version {
                    IntegrationConfigurationRow(label: "Version", value: version)
                }
            }
            if tool == .codex {
                Text("Nativ writes only ~/.codex/nativ.config.toml. Your default Codex app and ~/.codex/config.toml are left unchanged; the local model is selected only for CLI launches using --profile nativ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Show configuration in Finder") {
                viewModel.revealConfiguration(for: tool)
            }
            .buttonStyle(.link)
        }
    }

    private var launchCommandPanel: some View {
        IntegrationPanel(title: "Launch command", systemImage: "terminal") {
            if let workingDirectory,
               let command = viewModel.launchCommand(for: tool, workingDirectory: workingDirectory) {
                if tool == .codex {
                    Text("CLI")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text("This is the command opened in Terminal after the server is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        viewModel.copyLaunchCommand(for: tool, workingDirectory: workingDirectory)
                    } label: {
                        Label(tool == .codex ? "Copy CLI" : "Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Choose a model and project folder to generate the command.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Configure") {
                viewModel.configure(tool)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy || viewModel.selectedModelID == nil)

            Spacer()

            if tool == .codex {
                Button {
                    guard let workingDirectory else { return }
                    viewModel.configureAndOpen(tool, workingDirectory: workingDirectory)
                } label: {
                    if viewModel.activeOperation == tool {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…")
                        }
                    } else {
                        Label("Open CLI", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.selectedModelID == nil || workingDirectory == nil)
            } else {
                Button {
                    guard let workingDirectory else { return }
                    viewModel.configureAndOpen(tool, workingDirectory: workingDirectory)
                } label: {
                    if viewModel.activeOperation == tool {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…")
                        }
                    } else {
                        Label(status.isConfigured ? "Open \(tool.displayName)" : "Configure & Open", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.selectedModelID == nil || workingDirectory == nil)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project for \(tool.displayName)"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectory = url
        viewModel.rememberWorkingDirectory(url, for: tool)
    }

    private func formatContext(_ count: Int) -> String {
        count >= 1_000 ? "\(count / 1_000)K context" : "\(count) context"
    }
}

private struct IntegrationLogo: View {
    let tool: IntegrationTool
    let size: CGFloat

    var body: some View {
        Image(tool.logoAssetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            .accessibilityHidden(true)
    }
}

private struct IntegrationAvailabilityBadge: View {
    let status: IntegrationToolStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.executableURL == nil ? Color.secondary : (status.isConfigured ? .green : .orange))
                .frame(width: 7, height: 7)
            Text(status.executableURL == nil ? "Not installed" : (status.isConfigured ? "Configured" : "Not configured"))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

private struct IntegrationPanel<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct IntegrationConfigurationRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct IntegrationPill: View {
    let title: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }
}
