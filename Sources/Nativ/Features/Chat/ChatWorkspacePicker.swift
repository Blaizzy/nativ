import AppKit
import Combine
import NativServerKit
import SwiftUI

enum ChatWorkspaceMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case images = "Images"
    case decisions = "Decisions"

    var id: Self { self }
}

struct ChatWorkspacePicker: View {
    let selection: ChatWorkspaceMode
    let onSelect: (ChatWorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChatWorkspaceMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(
                            .system(
                                size: 12,
                                weight: mode == selection ? .semibold : .medium
                            )
                        )
                        .foregroundStyle(mode == selection ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if mode == selection {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.09))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.rawValue) workspace")
                .accessibilityAddTraits(mode == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.1), value: selection)
    }
}


struct DecisionComposerView: View {
    let model: NativModel
    @ObservedObject var request: DecisionRequestComposer
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    @StateObject private var localLibrary = LocalModelLibrary()
    @AppStorage("decisionComposerModelID") private var selectedModelID = ""
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case context, question, choices }

    private var models: [LocalModel] { localLibrary.models.filter { $0.capabilities.contains(.decision) } }
    private var selectedModel: LocalModel? { models.first { $0.repoID == selectedModelID } }
    private var isBusy: Bool { request.isRunning || model.isModelLoading || model.inferenceActivityInProgress }
    private var status: String {
        if request.isRunning { return "Evaluating… The first request may take longer while the model loads." }
        if localLibrary.isScanning { return "Scanning installed models…" }
        if let error = localLibrary.error { return error }
        if models.isEmpty { return "Download a decision model from Models to get started." }
        if selectedModel == nil { return "Choose an installed decision model." }
        if !model.isRunning { return "Start the server to run a decision request." }
        if isBusy { return "Wait for active inference or model loading to finish." }
        return request.validationMessage ?? "Ready to evaluate."
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Decision request").font(.title2.weight(.semibold))
                    Text("Context").font(.headline)
                    TextEditor(text: $request.context).frame(minHeight: 100).focused($focusedField, equals: .context)
                        .accessibilityLabel("Decision context")
                    Text("Question").font(.headline)
                    TextEditor(text: $request.question).frame(minHeight: 70).focused($focusedField, equals: .question)
                        .accessibilityLabel("Decision question")
                    Picker("Answer type", selection: $request.answerType) {
                        ForEach(DecisionRequestComposer.AnswerType.allCases) { Text($0.rawValue).tag($0) }
                    }.fixedSize()
                    if request.answerType != .bool {
                        Text(request.answerType == .score ? "Scale, from lowest to highest" : "Choices").font(.headline)
                        TextEditor(text: $request.choices).frame(minHeight: 90).focused($focusedField, equals: .choices)
                            .accessibilityLabel("Choices, one per line")
                        Text("One choice per line. At least two distinct choices.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = request.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let response = request.result, let answer = response.answers["answer"] {
                        Divider()
                        Text("Last result").font(.headline)
                        Text(request.resultQuestion).textSelection(.enabled)
                        Text(response.model).font(.caption).foregroundStyle(.secondary)
                        Text(answerText(answer.value)).font(.title3).textSelection(.enabled)
                        if !request.resultChoices.isEmpty {
                            Text("Score from 0 to \(request.resultChoices.count - 1), following the scale below.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let probability = answer.probability {
                            Text("Probability of Yes: \(probability.formatted(.percent.precision(.fractionLength(1))))")
                        }
                        if let probabilities = answer.probabilities {
                            Text("Probabilities").font(.subheadline.weight(.semibold))
                            ForEach(probabilities.keys.sorted(), id: \.self) { key in
                                HStack {
                                    Text(resultLabel(key))
                                    Spacer()
                                    Text((probabilities[key] ?? 0).formatted(.percent.precision(.fractionLength(1))))
                                }
                            }
                        }
                    }
                }
                .disabled(request.isRunning)
                .padding(24)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ChatWorkspacePicker(selection: .decisions, onSelect: onSelectWorkspaceMode)
                    Spacer()
                    modelPicker
                }
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if request.isRunning {
                        ProgressView().controlSize(.small)
                        Button("Stop") { request.cancel() }
                    } else if !model.isRunning {
                        Button("Start server") { model.startServer() }.disabled(model.isModelLoading)
                    } else {
                        Button("Run Decision", action: run).buttonStyle(.borderedProminent)
                            .disabled(isBusy || selectedModel == nil || request.validationMessage != nil)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            .frame(maxWidth: 752)
            .padding(24)
        }
        .background(Color.nativMainContentBackground.onTapGesture { focusedField = nil })
        .task(id: model.settings.localModelSearchPaths.cacheKey) { scanModels() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in scanModels() }
        .onReceive(HuggingFaceDownloadManager.shared.completedDownloads) { _ in scanModels() }
        .onDisappear { request.cancel(); localLibrary.cancel() }
    }

    private var modelPicker: some View {
        ComposerModelPicker(
            models: models, selectedModelID: selectedModelID.isEmpty ? nil : selectedModelID,
            selectedModelLabel: selectedModel?.displayName ?? "Choose Model",
            selectedModelProvider: selectedModel?.provider, selectedModelDetail: nil,
            showsFastIndicator: false, secondarySections: [], secondarySectionsForModel: nil,
            isModelLoading: request.isRunning, modelLoadingPercentage: nil, isDisabled: isBusy,
            statusLabel: localLibrary.isScanning ? "Scanning…" : "No installed decision models",
            helpText: "Choose a decision model", accessibilityValue: selectedModel?.displayName ?? "None",
            shortcutLabel: "⌃⇧M", emptyStateActionTitle: nil, onEmptyStateAction: nil,
            onSelectModel: { selectedModelID = $0.repoID }, onSwitchModel: { selectedModelID = $0 }
        )
    }

    private func scanModels() { localLibrary.scan(searchPaths: model.settings.localModelSearchPaths) }

    private func run() {
        guard let selectedModel else { return }
        focusedField = nil
        request.run { state, question in
            try await model.predictDecision(modelID: selectedModel.repoID, state: state, question: question)
        }
    }

    private func resultLabel(_ key: String) -> String {
        if let index = Int(key), request.resultChoices.indices.contains(index) { return request.resultChoices[index] }
        return key
    }

    private func answerText(_ value: MLXJSONValue) -> String {
        switch value {
        case .string(let text): text
        case .bool(let value): value ? "Yes" : "No"
        case .number(let number): number.formatted(.number.precision(.fractionLength(0...3)))
        default: String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
        }
    }
}
