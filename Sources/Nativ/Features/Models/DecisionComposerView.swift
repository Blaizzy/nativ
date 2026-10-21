import NativServerKit
import SwiftUI

struct DecisionComposerView: View {
    let model: NativModel
    @ObservedObject var request: DecisionRequestComposer
    let initialModel: LocalModel
    let onBack: () -> Void
    @State private var chosenModelID: String?
    @StateObject private var localLibrary = LocalModelLibrary()
    private var selectedModelID: String? { chosenModelID ?? initialModel.repoID }
    private var isLoaded: Bool { selectedModelID != nil && model.isRunning && model.metrics?.server.loadedDecisionModel == selectedModelID }
    private var isSelectedModelLoading: Bool { model.isModelLoading && model.modelLoadingID == selectedModelID }
    @FocusState private var focusedField: Field?
    @State private var inputFrames: [Field: CGRect] = [:]
    private enum Field: Hashable { case context, question, choices }

    private var models: [LocalModel] { localLibrary.models.filter { $0.capabilities.contains(.decision) } }
    private var selectedModel: LocalModel? { models.first { $0.repoID == selectedModelID } }
    private var isBusy: Bool { request.isRunning || model.isModelLoading || model.inferenceActivityInProgress }
    private var status: String? {
        if request.isCancelling { return "Stopping… Waiting for the current evaluation to finish." }
        if request.isRunning { return "Evaluating… Waiting for the decision model." }
        if localLibrary.isScanning { return "Scanning installed models…" }
        if let error = localLibrary.error { return error }
        if models.isEmpty { return "Download a decision model from Models to get started." }
        if selectedModel == nil { return "Choose an installed decision model." }
        if isSelectedModelLoading { return model.modelLoadingStatusText ?? "Loading decision model…" }
        if !model.isRunning { return "Start the server to run a decision request." }
        if let error = model.metrics?.server.decisionModelLoadError, !isLoaded { return error }
        if isBusy { return "Wait for active inference or model loading to finish." }
        if !isLoaded { return "Load the selected decision model to evaluate." }
        return request.validationMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Back to Models", systemImage: "chevron.left", action: onBack)
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 12)
                        Text("Decision request").font(.title2.weight(.semibold))
                        Text("Provide context, ask a question, and choose how to answer.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        input("Context", placeholder: "Describe the situation and include the relevant details…",
                              text: $request.context, field: .context, height: 120)
                        input("Question", placeholder: "What should the model decide?",
                              text: $request.question, field: .question, height: 76)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Answer format").font(.subheadline.weight(.medium))
                            Picker("Answer format", selection: $request.answerType) {
                                ForEach(DecisionRequestComposer.AnswerType.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        if request.answerType != .bool {
                            input(request.answerType == .score ? "Scale" : "Choices",
                                  placeholder: request.answerType == .score ? "Lowest level\nMiddle level\nHighest level" : "First choice\nSecond choice",
                                  text: $request.choices, field: .choices, height: 88)
                            Text(request.answerType == .score
                                 ? "One level per line, ordered from lowest to highest. At least two distinct levels."
                                 : "One choice per line. At least two distinct choices.")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, -12)
                        }
                    }
                    if let error = request.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let response = request.result, let answer = response.answers["answer"] {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Last result").font(.subheadline.weight(.medium))
                                Spacer()
                                Text(response.model).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(response.model)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(answerText(answer.value)).font(.title.weight(.semibold)).textSelection(.enabled)
                                Text(request.resultQuestion).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if !request.resultChoices.isEmpty {
                                Text("Score from 0 to \(request.resultChoices.count - 1), following the scale below.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let probability = answer.probability {
                                probabilityRow("Probability of Yes", value: probability)
                            }
                            if let probabilities = answer.probabilities {
                                Divider()
                                Text("Probabilities").font(.subheadline.weight(.medium))
                                ForEach(probabilities.keys.sorted(), id: \.self) { key in
                                    probabilityRow(resultLabel(key), value: probabilities[key] ?? 0)
                                }
                            }
                        }
                        .padding(20)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08), lineWidth: 1) }
                    }
                }
                .disabled(request.isRunning)
                .padding(24)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Decision model", systemImage: "arrow.triangle.branch")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    modelPicker
                }
                HStack {
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if request.isRunning {
                        ProgressView().controlSize(.small)
                        Button("Stop") { request.cancel() }.disabled(request.isCancelling)
                    } else if !model.isRunning {
                        Button("Start server") { model.startServer() }.disabled(model.isModelLoading)
                    } else if !isLoaded, let selectedModel {
                        Button("Load Model") { selectModel(selectedModel) }.disabled(isBusy)
                    } else {
                        Button("Run Decision", systemImage: "arrow.right", action: run)
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(isBusy || !isLoaded || selectedModel == nil || request.validationMessage != nil)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            .frame(maxWidth: 752)
            .padding(24)
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "decisionComposer")
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("decisionComposer"))
                .onEnded { event in
                    if !inputFrames.values.contains(where: { $0.contains(event.location) }) {
                        focusedField = nil
                    }
                }
        )
        .task(id: model.settings.localModelSearchPaths.cacheKey) { scanModels() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in scanModels() }
        .onReceive(HuggingFaceDownloadManager.shared.completedDownloads) { _ in scanModels() }
        .onDisappear { request.cancel(); localLibrary.cancel() }
    }

    private func input(_ title: String, placeholder: String, text: Binding<String>, field: Field, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium))
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: field)
                    .accessibilityLabel(title)
            }
            .font(.body)
            .padding(10)
            .frame(height: height)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("decisionComposer"))
            } action: { frame in
                inputFrames[field] = frame
            }
            .onDisappear { inputFrames.removeValue(forKey: field) }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(focusedField == field ? Color.accentColor.opacity(0.65) : .primary.opacity(0.1), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func probabilityRow(_ title: String, value: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.percent.precision(.fractionLength(1)))).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: min(max(value, 0), 1)).accessibilityLabel(title)
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(models) { localModel in
                Button {
                    selectModel(localModel)
                } label: {
                    if localModel.repoID == selectedModelID {
                        Label(localModel.displayName, systemImage: "checkmark")
                    } else {
                        Text(localModel.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if isSelectedModelLoading { ProgressView().controlSize(.small) }
                Text(selectedModel?.displayName ?? initialModel.displayName).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isBusy || models.isEmpty)
        .help("Choose a decision model")
        .accessibilityLabel("Decision model")
    }

    private func selectModel(_ localModel: LocalModel) {
        chosenModelID = localModel.repoID
        model.requestPreloadedModelSwitch(to: localModel, for: .decision, availableModels: localLibrary.models)
    }

    private func scanModels() { localLibrary.scan(searchPaths: model.settings.localModelSearchPaths) }

    private func run() {
        guard isLoaded, let selectedModel else { return }
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
