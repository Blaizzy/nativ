import AppKit
import Security
import SwiftUI

enum WelcomePreferences {
    static let completionKey = "hasCompletedWelcome1"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}

struct WelcomeGateView: View {
    @AppStorage(WelcomePreferences.completionKey) private var hasCompletedWelcome = false

    @ObservedObject var model: NativModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    let onComplete: (_ modelID: String?, _ serverAPIKey: String?) -> Void

    var body: some View {
        Group {
            if hasCompletedWelcome {
                ControlPanelView(
                    model: model,
                    navigation: navigation,
                    runtime: runtime
                )
            } else {
                WelcomeView(model: model) { modelID, serverAPIKey in
                    onComplete(modelID, serverAPIKey)
                    hasCompletedWelcome = true
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: hasCompletedWelcome)
    }
}

private struct WelcomeView: View {
    private enum Step: Equatable {
        case model
        case apiKey
    }

    @ObservedObject var model: NativModel
    @StateObject private var modelLibrary = LocalModelLibrary()
    @State private var step = Step.model
    @State private var selectedModelID: String?
    @State private var showsAPIKeyEditor = false
    @State private var serverAPIKey: String
    @FocusState private var isAPIKeyFieldFocused: Bool

    let onComplete: (_ modelID: String?, _ serverAPIKey: String?) -> Void

    init(
        model: NativModel,
        onComplete: @escaping (_ modelID: String?, _ serverAPIKey: String?) -> Void
    ) {
        self.model = model
        self.onComplete = onComplete
        let settings = model.settings.normalized()
        _selectedModelID = State(initialValue: settings.languageModelID)
        _serverAPIKey = State(initialValue: settings.serverAPIKey ?? WelcomeAPIKeyGenerator.makeKey())
    }

    var body: some View {
        ZStack {
            WelcomeBackground()

            VStack(spacing: 0) {
                welcomeHeader

                Group {
                    switch step {
                    case .model:
                        modelStep
                    case .apiKey:
                        apiKeyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: 760, maxHeight: 680)
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task(id: modelSearchPath) {
            modelLibrary.scan(path: model.settings.modelSearchPath)
        }
        .onDisappear {
            modelLibrary.cancel()
        }
    }

    private var welcomeHeader: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                .accessibilityLabel("Nativ app icon")

            VStack(spacing: 6) {
                Text("Welcome to Nativ")
                    .font(.system(size: 32, weight: .semibold))
                Text(step == .model
                    ? "Choose how your local server should start."
                    : "Optionally protect the server’s management endpoints.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                WelcomeStepIndicator(number: 1, title: "Model", isActive: step == .model)
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 34, height: 1)
                WelcomeStepIndicator(number: 2, title: "API Key", isActive: step == .apiKey)
            }
        }
        .padding(.bottom, 24)
    }

    private var modelStep: some View {
        VStack(spacing: 16) {
            WelcomeCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Select your first model")
                                .font(.headline)
                            Text("You can change this at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if modelLibrary.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                modelLibrary.scan(path: model.settings.modelSearchPath)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh installed models")
                        }
                    }
                    .padding(16)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            WelcomeModelPickerRow(
                                title: "Load on demand",
                                detail: "Start without preloading a model",
                                systemImage: "bolt.badge.clock",
                                isSelected: selectedModelID == nil
                            ) {
                                selectedModelID = nil
                            }

                            ForEach(pickerModels) { localModel in
                                WelcomeModelPickerRow(
                                    model: localModel,
                                    isSelected: selectedModelID == localModel.repoID
                                ) {
                                    selectedModelID = localModel.repoID
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(minHeight: 190, maxHeight: 280)

                    if let modelScanMessage {
                        Divider()
                        Label(modelScanMessage.text, systemImage: modelScanMessage.systemImage)
                            .font(.caption)
                            .foregroundStyle(modelScanMessage.isError ? Color.orange : Color.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .apiKey
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var apiKeyStep: some View {
        VStack(spacing: 16) {
            WelcomeCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.blue)
                            .frame(width: 38, height: 38)
                            .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Protect management access")
                                .font(.headline)
                            Text("An API key provides basic security if you're running Nativ on a shared network.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if showsAPIKeyEditor {
                        apiKeyEditor
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showsAPIKeyEditor = true
                                }
                                DispatchQueue.main.async {
                                    isAPIKeyFieldFocused = true
                                }
                            } label: {
                                Label("Set Up an API Key", systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button("Skip") {
                                finish(serverAPIKey: nil)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(20)
            }

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .model
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                if showsAPIKeyEditor {
                    Button("Skip") {
                        finish(serverAPIKey: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Save & Continue") {
                        finish(serverAPIKey: normalizedAPIKey)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedAPIKey == nil)
                }
            }
        }
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Server API key")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Generate New") {
                    serverAPIKey = WelcomeAPIKeyGenerator.makeKey()
                    isAPIKeyFieldFocused = true
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                TextField("API key", text: $serverAPIKey)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isAPIKeyFieldFocused)
                    .onSubmit {
                        if let normalizedAPIKey {
                            finish(serverAPIKey: normalizedAPIKey)
                        }
                    }

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(serverAPIKey, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy API key")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }

            Text("A secure random key is ready. Edit or replace it before saving if you prefer your own value.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pickerModels: [LocalModel] {
        modelLibrary.models.filter { localModel in
            localModel.repoID == selectedModelID
                || localModel.isEligibleForLanguageModelPicker
        }
    }

    private var modelSearchPath: String {
        model.settings.normalized().expandedModelSearchPath
    }

    private var normalizedAPIKey: String? {
        let trimmed = serverAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var modelScanMessage: (text: String, systemImage: String, isError: Bool)? {
        if let error = modelLibrary.error {
            return (error, "exclamationmark.triangle.fill", true)
        }
        if !modelLibrary.isScanning, pickerModels.isEmpty {
            return (
                "No compatible language models are installed. You can continue with load on demand.",
                "info.circle",
                false
            )
        }
        return nil
    }

    private func finish(serverAPIKey: String?) {
        onComplete(selectedModelID, serverAPIKey)
    }
}

private struct WelcomeCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 24, y: 10)
    }
}

private struct WelcomeStepIndicator: View {
    let number: Int
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.14), in: Circle())
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
    }
}

private struct WelcomeModelPickerRow: View {
    let title: String
    let detail: String
    let systemImage: String?
    let provider: LocalModelProvider?
    let memoryEstimate: LocalModelMemoryEstimate?
    let isSelected: Bool
    let action: () -> Void

    init(
        title: String,
        detail: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        provider = nil
        memoryEstimate = nil
        self.isSelected = isSelected
        self.action = action
    }

    init(model: LocalModel, isSelected: Bool, action: @escaping () -> Void) {
        title = model.repoID.split(separator: "/").last.map(String.init) ?? model.repoID
        detail = WelcomeModelPickerRow.modelDetail(model)
        systemImage = nil
        provider = model.provider
        memoryEstimate = model.memoryEstimate()
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                modelIcon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if let memoryEstimate, !memoryEstimate.isUsable {
                            WelcomeMemoryFitBadge(estimate: memoryEstimate)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider,
           let image = LocalModelProviderIcon.image(for: provider) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        } else {
            Image(systemName: systemImage ?? "cube.transparent.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private static func modelDetail(_ model: LocalModel) -> String {
        var details: [String] = []
        if let provider = model.provider {
            details.append(provider.displayName)
        }
        if let parameterSize = model.parameterSizeLabel {
            details.append(parameterSize)
        }
        if let quantization = model.quantizationLabel {
            details.append(quantization)
        }
        if let sizeBytes = model.sizeBytes {
            details.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        if let contextSize = model.contextSize {
            details.append("\(compactContextSize(contextSize)) context")
        }
        return details.isEmpty ? model.repoID : details.joined(separator: " · ")
    }

    private static func compactContextSize(_ value: Int) -> String {
        if value >= 1_048_576, value.isMultiple(of: 1_048_576) {
            return "\(value / 1_048_576)M"
        }
        if value >= 1024, value.isMultiple(of: 1024) {
            return "\(value / 1024)K"
        }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private var accessibilityLabel: String {
        let selection = isSelected ? "selected" : "not selected"
        guard let memoryEstimate else {
            return "\(title), \(selection)"
        }
        return "\(title), \(memoryEstimate.compatibilityLabel), \(selection)"
    }
}

private struct WelcomeMemoryFitBadge: View {
    let estimate: LocalModelMemoryEstimate

    var body: some View {
        Label(
            estimate.compatibilityLabel,
            systemImage: estimate.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(estimate.isUsable ? Color.green : Color.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            (estimate.isUsable ? Color.green : Color.orange).opacity(0.10),
            in: Capsule()
        )
        .fixedSize()
        .help(estimate.explanation)
    }
}

private struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear, Color.gray.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: -360, y: -250)
        }
        .ignoresSafeArea()
    }
}

private enum WelcomeAPIKeyGenerator {
    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return "nativ_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        }

        let token = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "nativ_\(token)"
    }
}

#Preview {
    WelcomeView(model: NativModel()) { _, _ in }
        .frame(width: 1240, height: 720)
}
