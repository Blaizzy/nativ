import Foundation

enum ChatImageOperation: String, Equatable, Sendable {
    case generate
    case edit

    init(toolName: String?) throws {
        switch toolName {
        case "generate_image":
            self = .generate
        case "edit_image":
            self = .edit
        default:
            throw ChatImageToolError.unsupportedTool(toolName ?? "unknown")
        }
    }

    var requiredCapability: LocalModelCapability {
        switch self {
        case .generate: .imageGeneration
        case .edit: .imageEditing
        }
    }

    var capabilityName: String {
        switch self {
        case .generate: "image generation"
        case .edit: "image editing"
        }
    }
}

struct ChatImageModelOption: Identifiable, Equatable, Sendable {
    var id: String { modelID }

    let displayName: String
    let modelID: String
    let capabilities: Set<LocalModelCapability>

    init(model: LocalModel) {
        let repositoryName = model.repoID.split(separator: "/").last.map(String.init)
        displayName = repositoryName ?? model.displayName
        modelID = model.repoID
        capabilities = model.capabilities
    }

    init(
        displayName: String,
        modelID: String,
        capabilities: Set<LocalModelCapability>
    ) {
        self.displayName = displayName
        self.modelID = modelID
        self.capabilities = capabilities
    }

    func supports(_ operation: ChatImageOperation) -> Bool {
        capabilities.contains(operation.requiredCapability)
    }
}

struct ChatImageModelSelectionRequest: Equatable, Sendable {
    let operation: ChatImageOperation
    let models: [ChatImageModelOption]
}

enum ChatImageModelResolution: Equatable, Sendable {
    case selected(ChatImageModelOption)
    case selectionRequired(ChatImageModelSelectionRequest)
    case installationRequired(ChatImageOperation)
}

enum ChatImageModelSelection {
    static func installedOptions(
        modelSearchPath: String,
        additionalModelSearchPaths: [String]
    ) async throws -> [ChatImageModelOption] {
        let models: [LocalModel]
        do {
            models = try await LocalModelDiscovery.scan(
                path: modelSearchPath,
                additionalPaths: additionalModelSearchPaths
            )
        } catch LocalModelDiscoveryError.pathNotFound {
            // A fresh install may not have a model cache directory yet.
            models = []
        }

        return models
            .map(ChatImageModelOption.init(model:))
            .sorted(by: modelOrder)
    }

    static func resolve(
        operation: ChatImageOperation,
        selectedModelID: String?,
        installedModels: [ChatImageModelOption]
    ) -> ChatImageModelResolution {
        let compatibleModels = compatibleModels(for: operation, in: installedModels)
        guard !compatibleModels.isEmpty else {
            return .installationRequired(operation)
        }

        if let selectedModelID = normalized(selectedModelID),
           let selectedModel = compatibleModels.first(where: {
               $0.modelID == selectedModelID
           }) {
            return .selected(selectedModel)
        }

        return .selectionRequired(ChatImageModelSelectionRequest(
            operation: operation,
            models: compatibleModels
        ))
    }

    static func compatibleModels(
        for operation: ChatImageOperation,
        in installedModels: [ChatImageModelOption]
    ) -> [ChatImageModelOption] {
        installedModels.filter { $0.supports(operation) }
    }

    static func selectedModel(
        withID modelID: String,
        from request: ChatImageModelSelectionRequest
    ) -> ChatImageModelOption? {
        request.models.first { $0.modelID == modelID }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func modelOrder(
        _ lhs: ChatImageModelOption,
        _ rhs: ChatImageModelOption
    ) -> Bool {
        let displayOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayOrder == .orderedSame {
            return lhs.modelID < rhs.modelID
        }
        return displayOrder == .orderedAscending
    }
}

@MainActor
final class ChatImageModelSelectionGate {
    private var pending: [UUID: CheckedContinuation<String?, Never>] = [:]

    var pendingCount: Int {
        pending.count
    }

    func select(modelID: String, for requestID: UUID) {
        pending.removeValue(forKey: requestID)?.resume(returning: modelID)
    }

    func cancel(_ requestID: UUID) {
        pending.removeValue(forKey: requestID)?.resume(returning: nil)
    }

    func awaitSelection(
        for requestID: UUID,
        onReady: () -> Void
    ) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.removeValue(forKey: requestID)?.resume(returning: nil)
                pending[requestID] = continuation
                onReady()
                if Task.isCancelled {
                    pending.removeValue(forKey: requestID)?.resume(returning: nil)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.pending.removeValue(forKey: requestID)?.resume(returning: nil)
            }
        }
    }
}
