import Foundation
import NativExtensionSDK

/// Chooses an installed model for a declarative workflow's `model.invoke` step.
///
/// Generalises `LocalModelDiscovery.speechToTextModelID(in:selectedModelID:)` to
/// every task, and borrows the actionable-failure shape from
/// `ChatImageModelSelection.resolve`.
enum NativTaskModelSelection {
    enum Resolution: Equatable {
        /// `substitutedFor` names the model the workflow asked for when it was
        /// unavailable, so the caller can say what it used instead.
        case resolved(modelID: String, substitutedFor: String?)
        case noCompatibleModel(task: NativWorkflowModelTask)
    }

    /// Which installed models can serve a task.
    static func isEligible(_ model: LocalModel, for task: NativWorkflowModelTask) -> Bool {
        switch task {
        case .language:
            // Not a raw `.text` check: that would admit drafters and rerankers.
            return model.isEligibleForLanguageModelPicker
        case .vision:
            return model.capabilities.contains(.vision)
                && !model.capabilities.contains(.imageGeneration)
        case .imageGeneration:
            return model.capabilities.contains(.imageGeneration)
        case .imageEditing:
            return model.capabilities.contains(.imageEditing)
        case .speechToText:
            return model.capabilities.contains(.speechToText)
        case .textToSpeech:
            return model.capabilities.contains(.textToSpeech)
        case .embedding:
            return model.capabilities.contains(.embeddings)
        }
    }

    /// The settings slot a user pins for this task. Vision has no slot of its
    /// own and shares the language pin, filtered by capability — so a pinned
    /// text-only model correctly falls through rather than being handed an
    /// image it cannot read.
    static func preloadSlot(for task: NativWorkflowModelTask) -> ModelPreloadSlot {
        switch task {
        case .language, .vision: .language
        case .imageGeneration, .imageEditing: .imageGeneration
        case .speechToText: .speechToText
        case .textToSpeech: .textToSpeech
        case .embedding: .embeddings
        }
    }

    /// Explicit request, then the user's pin, then the first compatible model.
    ///
    /// A named model that is not installed falls through rather than failing:
    /// a language model is fungible in a way an image model is not, and an
    /// extension should not break because the author's favourite is missing.
    /// The substitution is reported so the caller can say so.
    static func resolve(
        task: NativWorkflowModelTask,
        requested: String?,
        pinned: String?,
        installed: [LocalModel]
    ) -> Resolution {
        let eligible = installed
            .filter { isEligible($0, for: task) }
            .sorted { $0.repoID.localizedStandardCompare($1.repoID) == .orderedAscending }
        guard !eligible.isEmpty else {
            return .noCompatibleModel(task: task)
        }

        let wanted = requested.flatMap { $0 == "automatic" ? nil : $0 }
        if let wanted, eligible.contains(where: { $0.repoID == wanted }) {
            return .resolved(modelID: wanted, substitutedFor: nil)
        }
        if let pinned, eligible.contains(where: { $0.repoID == pinned }) {
            return .resolved(modelID: pinned, substitutedFor: wanted)
        }
        return .resolved(modelID: eligible[0].repoID, substitutedFor: wanted)
    }
}
