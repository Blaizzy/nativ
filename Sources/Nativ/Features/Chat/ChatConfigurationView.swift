import AppKit
import Foundation
import NativServerKit
import SwiftUI

private enum ModelConfigurationLayoutMetrics {
    static let contentMinimumWidth: CGFloat = 420
    static let contentMinimumWidthWithConfiguration: CGFloat = 360
    static let configurationWidth: CGFloat = 320
    static let transitionDuration: TimeInterval = 0.2
}

struct ModelConfigurationLayout<Content: View>: View {
    @ObservedObject var model: NativModel
    @Binding var isConfigurationVisible: Bool
    private let content: Content

    init(
        model: NativModel,
        isConfigurationVisible: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        _isConfigurationVisible = isConfigurationVisible
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                content
                    .frame(
                        minWidth: isConfigurationVisible
                            ? ModelConfigurationLayoutMetrics.contentMinimumWidthWithConfiguration
                            : ModelConfigurationLayoutMetrics.contentMinimumWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .clipped()

                Color.clear
                    .frame(
                        width: isConfigurationVisible
                            ? ModelConfigurationLayoutMetrics.configurationWidth
                            : 0
                    )
            }
            .animation(nil, value: isConfigurationVisible)

            if isConfigurationVisible {
                ModelConfigurationView(
                    settings: $model.settings,
                    settingsRequireRestart: model.settingsRequireRestart,
                    onReset: model.resetSettings
                )
                .frame(width: ModelConfigurationLayoutMetrics.configurationWidth)
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(
            .smooth(duration: ModelConfigurationLayoutMetrics.transitionDuration),
            value: isConfigurationVisible
        )
    }
}

struct ModelConfigurationView: View {
    @Binding var settings: NativSettings
    let settingsRequireRestart: Bool
    let onReset: () -> Void
    @State private var modelConfiguration: LocalModelConfigurationMetadata?
    @State private var isLoadingModelConfiguration = false
    @State private var modelConfigurationRevision = 0
    @StateObject private var draftModelLibrary = LocalModelLibrary()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    modelContextSection
                    kvQuantizationSection
                    thinkingSection
                    samplingSection
                    speculativeDecodingSection
                    structuredOutputSection
                    prefixCachingSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(.container, edges: [.top, .bottom, .trailing])
        }
        .task(id: modelConfigurationLookupID) {
            await loadModelConfiguration(for: modelConfigurationLookupID)
        }
        .task(id: draftModelScanKey) {
            scanDraftModelLibraryIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            modelConfigurationRevision += 1
            scanDraftModelLibraryIfNeeded()
        }
    }

    private var draftModelScanKey: String {
        let normalizedSettings = settings.normalized()
        return ([
            String(normalizedSettings.speculativeDecodingEnabled),
            normalizedSettings.modelSearchPath
        ] + normalizedSettings.additionalModelSearchPaths)
            .joined(separator: "\u{0}")
    }

    private func scanDraftModelLibraryIfNeeded() {
        guard settings.speculativeDecodingEnabled else {
            return
        }
        draftModelLibrary.scan(
            path: settings.modelSearchPath,
            additionalPaths: settings.normalized().additionalModelSearchPaths
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Model Configuration", systemImage: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 0)

                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset model configuration")
            }

            if settingsRequireRestart {
                Label("Server restart required", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text("Request settings apply to the next message.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 52)
        .padding(.top, 13)
        .padding(.bottom, 16)
    }

    private var modelContextSection: some View {
        ChatConfigurationSection(title: "Model Context") {
            ConfigurationIntegerField(
                title: "Max output",
                value: $settings.maxTokens,
                range: 1...262_144
            )

            ConfigurationIntegerField(
                title: "Context window",
                value: modelContextBinding,
                range: 0...1_048_576
            )
            .disabled(isLoadingModelConfiguration)

            VStack(alignment: .leading, spacing: 8) {
                Text("System prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if settings.systemPrompt.isEmpty {
                        Text(systemPromptPlaceholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $settings.systemPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
                .frame(minHeight: 88)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }

                Text(systemPromptHint)
                    .configurationHintStyle()
            }
        }
    }

    private var modelConfigurationLookupID: String {
        let normalizedSettings = settings.normalized()
        return [
            normalizedSettings.modelSearchPath,
            normalizedSettings.languageModelID ?? "",
            String(modelConfigurationRevision)
        ].joined(separator: "\u{0}")
    }

    private func loadModelConfiguration(for lookupID: String) async {
        modelConfiguration = nil
        guard let modelID = settings.normalized().languageModelID else {
            isLoadingModelConfiguration = false
            return
        }

        isLoadingModelConfiguration = true
        let metadata = await LocalModelDiscovery.configurationMetadata(
            repoID: modelID,
            path: settings.modelSearchPath
        )
        guard lookupID == modelConfigurationLookupID else {
            return
        }
        modelConfiguration = metadata
        isLoadingModelConfiguration = false
    }

    private var modelContextBinding: Binding<Int> {
        Binding(
            get: {
                settings.maxKVSize > 0
                    ? settings.maxKVSize
                    : (modelConfiguration?.contextSize ?? 0)
            },
            set: { value in
                if value == modelConfiguration?.contextSize {
                    settings.maxKVSize = 0
                } else {
                    settings.maxKVSize = value
                }
            }
        )
    }

    private var systemPromptPlaceholder: String {
        if isLoadingModelConfiguration {
            return "Reading chat template…"
        }
        return modelConfiguration?.defaultSystemPrompt ?? "Optional custom system prompt"
    }

    private var systemPromptHint: String {
        if isLoadingModelConfiguration {
            return "Looking for a default system prompt in the chat template."
        }
        if modelConfiguration?.defaultSystemPrompt != nil {
            return settings.systemPrompt.isEmpty
                ? "Template default shown above. Enter text to override it."
                : "Custom prompt overrides the model's chat-template default."
        }
        return "No default system prompt was found in the chat template."
    }

    private var kvQuantizationSection: some View {
        ChatConfigurationSection(title: "KV Quantization") {
            Toggle("Quantize KV cache", isOn: $settings.kvQuantizationEnabled)
                .configurationToggleStyle()

            if settings.kvQuantizationEnabled {
                Toggle("TurboQuant", isOn: turboQuantBinding)
                    .configurationToggleStyle()

                ConfigurationDoubleField(
                    title: "KV bits",
                    value: $settings.kvBits,
                    range: 2...16
                )

                if !settings.turboQuantEnabled {
                    ConfigurationIntegerField(
                        title: "Group size",
                        value: $settings.kvGroupSize,
                        range: 1...1024
                    )
                }

                ConfigurationIntegerField(
                    title: "Quantize after",
                    value: $settings.quantizedKVStart,
                    range: 0...1_048_576
                )

                Text("Changes to the KV cache require a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var thinkingSection: some View {
        ChatConfigurationSection(title: "Thinking") {
            Toggle("Enable Thinking", isOn: $settings.thinkingEnabled)
                .configurationToggleStyle()

            if settings.thinkingEnabled {
                Toggle("Limit thinking", isOn: thinkingBudgetBinding)
                    .configurationToggleStyle()
                    .disabled(settings.speculativeDecodingActive)

                if settings.speculativeDecodingActive {
                    Text("Thinking limits are unavailable while speculative decoding is active.")
                        .configurationHintStyle()
                } else if settings.thinkingBudgetEnabled {
                    ConfigurationIntegerField(
                        title: "Budget",
                        value: $settings.thinkingBudget,
                        range: 1...262_144
                    )
                }
                ConfigurationTextField(title: "Start token", text: $settings.thinkingStartToken)
                ConfigurationTextField(title: "EOS token", text: $settings.thinkingEndToken)
            }
        }
    }

    private var samplingSection: some View {
        ChatConfigurationSection(title: "Sampling") {
            ConfigurationDoubleField(
                title: "Temperature",
                value: $settings.temperature,
                range: 0...2
            )
            ConfigurationIntegerField(
                title: "Top K",
                value: $settings.topK,
                range: 0...10_000
            )
            ConfigurationDoubleField(
                title: "Top P",
                value: $settings.topP,
                range: 0...1
            )
            ConfigurationDoubleField(
                title: "Min P",
                value: $settings.minP,
                range: 0...1
            )

            Toggle("Repetition penalty", isOn: $settings.repetitionPenaltyEnabled)
                .configurationToggleStyle()

            if settings.repetitionPenaltyEnabled {
                ConfigurationDoubleField(
                    title: "Penalty",
                    value: $settings.repetitionPenalty,
                    range: 0...4
                )
            }
        }
    }

    private var speculativeDecodingSection: some View {
        ChatConfigurationSection(title: "Speculative Decoding") {
            Toggle("Enable drafter", isOn: speculativeDecodingBinding)
                .configurationToggleStyle()

            if settings.speculativeDecodingEnabled {
                HStack(alignment: .bottom, spacing: 8) {
                    ConfigurationTextField(title: "Draft model", text: $settings.draftModelID)
                    draftModelMenu
                }

                HStack(spacing: 8) {
                    Text("Family")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.draftKind) {
                        Text("Auto").tag("auto")
                        Text("DFlash").tag("dflash")
                        Text("EAGLE3").tag("eagle3")
                        Text("MTP").tag("mtp")
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                .font(.body)

                ConfigurationIntegerField(
                    title: "Block size",
                    value: $settings.draftBlockSize,
                    range: 0...1024
                )

                Text(draftModelHint.text)
                    .configurationHintStyle(isError: draftModelHint.isError)
            }
        }
    }

    private var draftModelMenu: some View {
        Menu {
            if !installedDrafters.isEmpty {
                Section("Installed drafters") {
                    ForEach(installedDrafters) { model in
                        Button(draftMenuTitle(for: model)) {
                            settings.draftModelID = model.repoID
                        }
                    }
                }
            }
            if !otherDraftCandidates.isEmpty {
                Section("Other installed models") {
                    ForEach(otherDraftCandidates) { model in
                        Button(model.displayName) {
                            settings.draftModelID = model.repoID
                        }
                    }
                }
            }
            if installedDrafters.isEmpty && otherDraftCandidates.isEmpty {
                Button(draftModelLibrary.isScanning ? "Scanning models…" : "No installed models found") {}
                    .disabled(true)
            }
            Divider()
            Button("Refresh") {
                scanDraftModelLibraryIfNeeded()
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose an installed model as the drafter")
    }

    private var installedDrafters: [LocalModel] {
        draftModelLibrary.models.filter { $0.drafterKind != nil }
    }

    private var otherDraftCandidates: [LocalModel] {
        draftModelLibrary.models.filter {
            $0.drafterKind == nil
                && $0.isEligibleForLanguageModelPicker
                && $0.repoID != settings.normalized().languageModelID
        }
    }

    private func draftMenuTitle(for model: LocalModel) -> String {
        var title = model.displayName
        if let kindLabel = model.drafterKindLabel {
            title += " (\(kindLabel))"
        }
        if isDrafterIncompatible(model) {
            title += " — different target"
        }
        return title
    }

    private func isDrafterIncompatible(_ model: LocalModel) -> Bool {
        guard let drafterHiddenSize = model.hiddenSize,
              let targetHiddenSize = modelConfiguration?.hiddenSize
        else {
            return false
        }
        return drafterHiddenSize != targetHiddenSize
    }

    private var draftModelHint: (text: String, isError: Bool) {
        let trimmedID = settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty {
            return ("Enter or choose a drafter model to activate speculative decoding.", true)
        }
        guard let selected = draftModelLibrary.models.first(where: {
            $0.repoID == trimmedID
        }) else {
            return ("The drafter is loaded after the next server restart.", false)
        }
        if isDrafterIncompatible(selected),
           let drafterHiddenSize = selected.hiddenSize,
           let targetHiddenSize = modelConfiguration?.hiddenSize {
            return (
                "This drafter was built for a different target model (hidden size \(drafterHiddenSize) vs \(targetHiddenSize)). The server will reject it.",
                true
            )
        }
        if let kindLabel = selected.drafterKindLabel {
            return ("Detected \(kindLabel) drafter. Loaded after the next server restart.", false)
        }
        return (
            "No drafter metadata found in this model. Speculative decoding may fall back to DFlash or fail to load.",
            false
        )
    }

    private var structuredOutputSection: some View {
        ChatConfigurationSection(title: "Structured Output") {
            Toggle("Enforce JSON schema", isOn: structuredOutputBinding)
                .configurationToggleStyle()

            if settings.structuredOutputEnabled {
                ConfigurationTextField(title: "Schema name", text: $settings.structuredOutputName)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("JSON schema")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Button("Reset") {
                            settings.structuredOutputSchema = NativSettings.defaultStructuredOutputSchema
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                    }

                    TextEditor(text: $settings.structuredOutputSchema)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 128)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    settings.structuredOutputValidationError == nil
                                        ? Color(nsColor: .separatorColor)
                                        : Color.red.opacity(0.7),
                                    lineWidth: 0.5
                                )
                        }
                }

                if let error = settings.structuredOutputValidationError {
                    Text(error)
                        .configurationHintStyle(isError: true)
                }
            }
        }
    }

    private var prefixCachingSection: some View {
        ChatConfigurationSection(title: "Prefix Caching") {
            Toggle("Enable automatic caching", isOn: $settings.prefixCachingEnabled)
                .configurationToggleStyle()

            if settings.prefixCachingEnabled {
                ConfigurationIntegerField(
                    title: "Cache blocks",
                    value: $settings.prefixCacheBlocks,
                    range: 1...1_048_576
                )
                ConfigurationIntegerField(
                    title: "Tokens per block",
                    value: $settings.prefixCacheBlockSize,
                    range: 1...4096
                )
                Text("Shared prompt prefixes are reused after a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var turboQuantBinding: Binding<Bool> {
        Binding(
            get: { settings.turboQuantEnabled },
            set: { enabled in
                settings.turboQuantEnabled = enabled
                if enabled, settings.kvBits == 8 {
                    settings.kvBits = 3.5
                } else if !enabled, settings.kvBits == 3.5 {
                    settings.kvBits = 8
                }
            }
        )
    }

    private var speculativeDecodingBinding: Binding<Bool> {
        Binding(
            get: { settings.speculativeDecodingEnabled },
            set: { enabled in
                settings.speculativeDecodingEnabled = enabled
                if enabled {
                    settings.structuredOutputEnabled = false
                    settings.thinkingBudgetEnabled = false
                }
            }
        )
    }

    private var thinkingBudgetBinding: Binding<Bool> {
        Binding(
            get: { settings.thinkingBudgetEnabled && !settings.speculativeDecodingActive },
            set: { settings.thinkingBudgetEnabled = $0 }
        )
    }

    private var structuredOutputBinding: Binding<Bool> {
        Binding(
            get: { settings.structuredOutputEnabled },
            set: { enabled in
                settings.structuredOutputEnabled = enabled
                if enabled {
                    settings.speculativeDecodingEnabled = false
                }
            }
        )
    }
}

private struct ChatConfigurationSection<Content: View>: View {
    let title: String
    private let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct ConfigurationIntegerField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", value: $value, format: .number)
                .font(.body)
                .multilineTextAlignment(.trailing)
                .frame(width: 104)
                .onChange(of: value) { _, newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
    }
}

private struct ConfigurationDoubleField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField(
                "",
                value: $value,
                format: .number.precision(.fractionLength(0...3))
            )
            .font(.body)
            .multilineTextAlignment(.trailing)
            .frame(width: 104)
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        }
    }
}

private struct ConfigurationTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.body)
        }
    }
}

private extension View {
    func configurationToggleStyle() -> some View {
        toggleStyle(.switch)
            .controlSize(.regular)
            .font(.body)
    }

    func configurationHintStyle(isError: Bool = false) -> some View {
        font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
