import Combine
import NativServerKit
import Foundation

@MainActor
final class DecisionRequestComposer: ObservableObject {
    enum AnswerType: String, CaseIterable, Identifiable {
        case choice = "Single choice"
        case bool = "Yes / No"
        case score = "Ordered scale"
        var id: Self { self }
        var kind: NativDecisionQuestion.Kind {
            switch self {
            case .choice: .choice
            case .bool: .bool
            case .score: .score
            }
        }
    }

    @Published var context = ""
    @Published var question = ""
    @Published var choices = ""
    @Published var answerType: AnswerType = .choice
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var error: String?
    @Published private(set) var result: NativDecisionResponse?
    @Published private(set) var resultQuestion = ""
    @Published private(set) var resultChoices: [String] = []
    private var task: Task<Void, Never>?
    private var runID: UUID?

    var labels: [String] {
        choices.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var validationMessage: String? {
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter context for the decision." }
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a question." }
        if answerType != .bool {
            if labels.count < 2 { return "Enter at least two choices, one per line." }
            if Set(labels).count != labels.count { return "Each choice must be unique." }
        }
        return nil
    }

    func run(predict: @escaping @MainActor (MLXJSONValue, NativDecisionQuestion) async throws -> NativDecisionResponse) {
        guard !isRunning else { return }
        guard validationMessage == nil else { error = validationMessage; return }
        let id = UUID()
        runID = id
        isRunning = true
        isCancelling = false
        error = nil
        result = nil
        resultQuestion = question
        resultChoices = answerType == .score ? labels : []
        let state = MLXJSONValue.string(context)
        let request = NativDecisionQuestion(type: answerType.kind, instructions: question,
            criteria: answerType == .bool ? nil : .array(labels.map(MLXJSONValue.string)))
        task = Task { [weak self] in
            defer {
                if let self, self.runID == id {
                    self.isRunning = false
                    self.isCancelling = false
                    self.task = nil
                }
            }
            do {
                let response = try await predict(state, request)
                try Task.checkCancellation()
                guard let self, self.runID == id, !self.isCancelling else { return }
                self.result = response
            } catch is CancellationError {
            } catch {
                guard let self, self.runID == id, !self.isCancelling else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
    }
}
