import Foundation
import NativServerKit

enum ChatImageOperation: String, Equatable, Sendable {
    case generate
    case edit

    init(toolName: String?) throws {
        switch toolName {
        case ChatImageToolRegistry.generateToolName:
            self = .generate
        case ChatImageToolRegistry.editToolName:
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
    enum Availability: Equatable, Sendable {
        case installed
        case downloadable(sizeBytes: Int64?)
    }

    var id: String { modelID }

    let displayName: String
    let modelID: String
    let capabilities: Set<LocalModelCapability>
    let availability: Availability

    var isInstalled: Bool {
        availability == .installed
    }

    var downloadSizeBytes: Int64? {
        guard case .downloadable(let sizeBytes) = availability else {
            return nil
        }
        return sizeBytes
    }

    init(model: LocalModel) {
        let repositoryName = model.repoID.split(separator: "/").last.map(String.init)
        displayName = repositoryName ?? model.displayName
        modelID = model.repoID
        capabilities = model.capabilities
        availability = .installed
    }

    init(
        downloadableModel model: HuggingFaceModel,
        capabilities: Set<LocalModelCapability>,
        sizeBytes: Int64
    ) {
        displayName = Self.repositoryName(from: model.id)
        modelID = model.id
        self.capabilities = capabilities
        availability = .downloadable(sizeBytes: sizeBytes)
    }

    init(
        displayName: String,
        modelID: String,
        capabilities: Set<LocalModelCapability>,
        availability: Availability = .installed
    ) {
        self.displayName = displayName
        self.modelID = modelID
        self.capabilities = capabilities
        self.availability = availability
    }

    func supports(_ operation: ChatImageOperation) -> Bool {
        capabilities.contains(operation.requiredCapability)
    }

    private static func repositoryName(from modelID: String) -> String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }
}

struct ChatImageModelSelectionRequest: Equatable, Sendable {
    let operation: ChatImageOperation
    let models: [ChatImageModelOption]

    var installedModels: [ChatImageModelOption] {
        models.filter(\.isInstalled)
    }

    var downloadableModels: [ChatImageModelOption] {
        models.filter { !$0.isInstalled }
    }
}

enum ChatImageModelResolution: Equatable, Sendable {
    case selected(ChatImageModelOption)
    case selectionRequired(ChatImageModelSelectionRequest)
}

enum ChatImageModelSelection {
    typealias RecommendationLoader = @Sendable (
        LocalModelCapability,
        String?
    ) async throws -> [HuggingFaceModel]

    static let recommendedModelCount = 3
    private static let supportedDownloadableModelFamilies =
        (try? Nativ.imageGenerationModelTypes()) ?? []

    static func availableOptions(
        for operation: ChatImageOperation,
        modelSearchPath: String,
        additionalModelSearchPaths: [String],
        huggingFaceToken: String?,
        preferredInstalledModelID: String? = nil,
        recommendationLoader: RecommendationLoader = { capability, token in
            try await HuggingFaceModelCatalog.popularModels(
                with: capability,
                token: token
            )
        }
    ) async throws -> [ChatImageModelOption] {
        let installedModels = try await installedOptions(
            modelSearchPath: modelSearchPath,
            additionalModelSearchPaths: additionalModelSearchPaths
        )
        let compatibleInstalledModels = compatibleModels(
            for: operation,
            in: installedModels
        )

        guard needsRecommendations(
            preferredInstalledModelID: preferredInstalledModelID,
            installedModels: compatibleInstalledModels
        ) else {
            return compatibleInstalledModels
        }

        let downloadableModels: [ChatImageModelOption]
        do {
            let installedModelIDs = Set(compatibleInstalledModels.map(\.modelID))
            let candidates = try await recommendationLoader(
                operation.requiredCapability,
                huggingFaceToken
            )
            .filter { !$0.isPrivate && !$0.isGated }
            .compactMap { model -> (HuggingFaceModel, Set<LocalModelCapability>)? in
                let capabilities = downloadableCapabilities(
                    modelID: model.id,
                    tags: model.tags
                )
                guard capabilities.contains(operation.requiredCapability) else {
                    return nil
                }
                return (model, capabilities)
            }
            .filter { !installedModelIDs.contains($0.0.id) }
            downloadableModels = await resolvedDownloadOptions(
                Array(candidates.prefix(recommendedModelCount))
            )
        } catch {
            // Hub access is optional. When the device is offline, the picker
            // remains useful and shows only models already on the device.
            downloadableModels = []
        }

        return displayOptions(
            for: operation,
            installedModels: compatibleInstalledModels,
            downloadableModels: downloadableModels
        )
    }

    static func installedOptions(
        modelSearchPath: String,
        additionalModelSearchPaths: [String]
    ) async throws -> [ChatImageModelOption] {
        let models: [LocalModel]
        do {
            models = try await LocalModelDiscovery.scan(
                searchPaths: LocalModelSearchPaths(
                    primary: modelSearchPath,
                    additional: additionalModelSearchPaths
                )
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
        availableModels: [ChatImageModelOption]
    ) -> ChatImageModelResolution {
        let compatibleModels = compatibleModels(for: operation, in: availableModels)
        if let selectedModelID = normalized(selectedModelID),
           let selectedModel = compatibleModels.first(where: {
               $0.modelID == selectedModelID && $0.isInstalled
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
        in models: [ChatImageModelOption]
    ) -> [ChatImageModelOption] {
        models.filter { $0.supports(operation) }
    }

    static func downloadableCapabilities(
        modelID: String,
        tags: [String]
    ) -> Set<LocalModelCapability> {
        let descriptors = ([modelID] + tags).joined(separator: " ").lowercased()
        guard !["gguf", "lora", "adapter", "controlnet"].contains(where: {
            descriptors.contains($0)
        }) else {
            return []
        }
        let name = modelID.split(separator: "/").last.map(String.init)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? ""
        let family: String? = if name.contains("flux2") || name.contains("flux_2") {
            "flux2"
        } else if name.contains("bonsai") {
            "bonsai"
        } else if name.contains("ideogram_4") || name.contains("ideogram4") {
            "ideogram4"
        } else if name.contains("mage_flow") {
            "mage_flow"
        } else {
            nil
        }
        guard let family, supportedDownloadableModelFamilies.contains(family) else {
            return []
        }
        if family == "flux2" {
            return [.imageGeneration, .imageEditing]
        }
        if family == "mage_flow", MLXImageModelResolver.isKnownImageEditOnlyModelID(modelID) {
            return [.imageEditing]
        }
        return [.imageGeneration]
    }

    private static func resolvedDownloadOptions(
        _ candidates: [(HuggingFaceModel, Set<LocalModelCapability>)]
    ) async -> [ChatImageModelOption] {
        await withTaskGroup(of: (Int, ChatImageModelOption?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let size: Int64?
                    if let estimate = candidate.0.estimatedDownloadBytes {
                        size = estimate
                    } else {
                        size = await HubModelSizeResolver.shared.resolveSize(for: candidate.0.id)
                    }
                    guard let size else { return (index, nil) }
                    return (index, ChatImageModelOption(
                        downloadableModel: candidate.0,
                        capabilities: candidate.1,
                        sizeBytes: size
                    ))
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
                .sorted { $0.0 < $1.0 }
                .compactMap(\.1)
        }
    }

    static func displayOptions(
        for operation: ChatImageOperation,
        installedModels: [ChatImageModelOption],
        downloadableModels: [ChatImageModelOption]
    ) -> [ChatImageModelOption] {
        let installed = compatibleModels(for: operation, in: installedModels)
            .sorted(by: modelOrder)

        var includedModelIDs = Set(installed.map(\.modelID))
        var recommendations: [ChatImageModelOption] = []
        for option in compatibleModels(for: operation, in: downloadableModels) {
            guard !option.isInstalled,
                  includedModelIDs.insert(option.modelID).inserted
            else {
                continue
            }
            recommendations.append(option)
            if recommendations.count == recommendedModelCount {
                break
            }
        }

        return installed + recommendations
    }

    static func needsRecommendations(
        preferredInstalledModelID: String?,
        installedModels: [ChatImageModelOption]
    ) -> Bool {
        if let preferredInstalledModelID = normalized(preferredInstalledModelID),
           installedModels.contains(where: { $0.modelID == preferredInstalledModelID }) {
            return false
        }
        return true
    }

    static func selectedModel(
        withID modelID: String,
        from request: ChatImageModelSelectionRequest
    ) -> ChatImageModelOption? {
        request.models.first { $0.modelID == modelID }
    }

    static func isPrepared(
        modelID: String,
        for operation: ChatImageOperation,
        installedModels: [ChatImageModelOption]
    ) -> Bool {
        installedModels.contains { $0.modelID == modelID && $0.supports(operation) }
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
