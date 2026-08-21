import Foundation

extension Notification.Name {
    static let localModelLibraryDidChange = Notification.Name("LocalModelLibraryDidChange")
}

struct LocalModelSearchPaths: Hashable, Sendable {
    let primary: String
    let additional: [String]

    init(primary: String, additional: [String] = []) {
        let expandedPrimary = LocalModelDiscovery.expandedPath(primary)
        self.primary = expandedPrimary

        var seen = Set([expandedPrimary])
        self.additional = additional
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(LocalModelDiscovery.expandedPath)
            .filter { seen.insert($0).inserted }
    }

    var all: [String] { [primary] + additional }

    var cacheKey: String { all.joined(separator: "\u{0}") }
}

enum LocalModelCapability: String, CaseIterable, Hashable, Sendable {
    case text
    case vision
    case audio
    case video
    case imageGeneration
    case imageEditing
    case speechToText
    case textToSpeech
    case embeddings
    case reranking
    case reasoning
    case tools
    case drafter

    var displayName: String {
        switch self {
        case .text:
            "Text"
        case .vision:
            "Vision"
        case .audio:
            "Audio"
        case .video:
            "Video"
        case .imageGeneration:
            "Image Generation"
        case .imageEditing:
            "Image Editing"
        case .speechToText:
            "Speech to Text"
        case .textToSpeech:
            "Text to Speech"
        case .embeddings:
            "Embeddings"
        case .reranking:
            "Reranking"
        case .reasoning:
            "Reasoning"
        case .tools:
            "Tool Calling"
        case .drafter:
            "Drafter"
        }
    }
}

enum LocalModelSource: String, Equatable, Sendable {
    case huggingFaceCache
    case external

    var badgeLabel: String? {
        switch self {
        case .huggingFaceCache: nil
        case .external: "External"
        }
    }
}

struct LocalModel: Identifiable, Equatable, Sendable {
    var id: String { repoID }

    let repoID: String
    let snapshotURL: URL?
    let modifiedAt: Date?
    let sizeBytes: Int64?
    let parameterCount: Int64?
    let quantizationBits: Int?
    let quantizationGroupSize: Int?
    let contextSize: Int?
    let provider: LocalModelProvider?
    let capabilities: Set<LocalModelCapability>
    let drafterKind: String?
    let hiddenSize: Int?
    var source: LocalModelSource = .huggingFaceCache

    var displayName: String {
        guard source != .huggingFaceCache, let snapshotURL else {
            return repoID
        }
        let components = snapshotURL.standardizedFileURL.pathComponents.suffix(2)
        return components.joined(separator: "/")
    }

    var isDeletable: Bool {
        source == .huggingFaceCache
    }

    var isEligibleForLanguageModelPicker: Bool {
        // Any text-generative model qualifies (chat + omni), even if it also carries an
        // image-generation tag. A vision model qualifies only when it isn't image-gen/editing.
        guard !capabilities.contains(.drafter), !capabilities.contains(.reranking) else {
            return false
        }
        return capabilities.contains(.text)
            || (capabilities.contains(.vision) && !capabilities.contains(.imageGeneration))
    }

    var drafterKindLabel: String? {
        switch drafterKind {
        case "mtp":
            "MTP"
        case "eagle3":
            "EAGLE3"
        case "dflash":
            "DFlash"
        default:
            nil
        }
    }

    var parameterSizeLabel: String? {
        guard let parameterCount, parameterCount > 0 else {
            return nil
        }
        if parameterCount >= 1_000_000_000 {
            return Self.compactCount(Double(parameterCount) / 1_000_000_000, suffix: "B")
        }
        if parameterCount >= 1_000_000 {
            return Self.compactCount(Double(parameterCount) / 1_000_000, suffix: "M")
        }
        return NumberFormatter.localizedString(
            from: NSNumber(value: parameterCount),
            number: .decimal
        )
    }

    var quantizationLabel: String? {
        quantizationBits.map { "\($0)-bit" }
    }

    func memoryEstimate(
        totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> LocalModelMemoryEstimate? {
        guard totalMemoryBytes > 0 else {
            return nil
        }

        var estimates: [Double] = []
        if let sizeBytes, sizeBytes > 0 {
            estimates.append(Double(sizeBytes))
        }

        if let parameterCount, parameterCount > 0 {
            let bitsPerParameter = Double(quantizationBits ?? 16)
            var bytesPerParameter = bitsPerParameter / 8

            // MLX quantization stores a scale and bias (two Float16 values) per group.
            if quantizationBits != nil,
               let quantizationGroupSize,
               quantizationGroupSize > 0 {
                bytesPerParameter += 4 / Double(quantizationGroupSize)
            }
            estimates.append(Double(parameterCount) * bytesPerParameter)
        }

        guard let estimatedBytes = estimates.max(),
              estimatedBytes.isFinite,
              estimatedBytes > 0,
              estimatedBytes <= Double(Int64.max)
        else {
            return nil
        }

        let memoryBudgetBytes = UInt64(
            (Double(totalMemoryBytes) * (1 - LocalModelMemoryEstimate.headroomFraction))
                .rounded(.down)
        )
        return LocalModelMemoryEstimate(
            estimatedModelBytes: UInt64(estimatedBytes.rounded(.up)),
            memoryBudgetBytes: memoryBudgetBytes,
            totalMemoryBytes: totalMemoryBytes,
            activationReserveBytes: LocalModelMemoryEstimate.activationReserveBytes(for: capabilities)
        )
    }

    private static func compactCount(_ value: Double, suffix: String) -> String {
        if value.rounded() == value {
            return "\(Int(value))\(suffix)"
        }
        return String(format: "%.1f%@", value, suffix)
    }
}

/// Resolves which chat model a drafter model (MTP/EAGLE/DFlash) accelerates when the
/// user picks the drafter from the chat model menu. Selecting a drafter enables
/// speculative decoding on its compatible target instead of loading the drafter itself.
enum DrafterTargetResolver {
    static func compatibleTarget(
        for drafter: LocalModel,
        currentModelID: String?,
        models: [LocalModel]
    ) -> LocalModel? {
        let chatModels = models.filter { $0.isEligibleForLanguageModelPicker }

        if let currentModelID,
           let current = chatModels.first(where: { $0.repoID == currentModelID }),
           isCompatible(drafter: drafter, target: current) {
            return current
        }

        for candidate in targetNameCandidates(from: drafter.repoID) {
            if let match = chatModels.first(where: { $0.repoID == candidate }),
               isCompatible(drafter: drafter, target: match) {
                return match
            }
        }

        return chatModels.first { isCompatible(drafter: drafter, target: $0) }
    }

    // Same rule as ChatConfigurationView.isDrafterIncompatible: a hidden-size
    // mismatch is incompatible, missing metadata is treated as compatible.
    static func isCompatible(drafter: LocalModel, target: LocalModel) -> Bool {
        guard let drafterHiddenSize = drafter.hiddenSize,
              let targetHiddenSize = target.hiddenSize else {
            return true
        }
        return drafterHiddenSize == targetHiddenSize
    }

    /// "mlx-community/Qwen3.8-27B-MTP-8bit" → "mlx-community/Qwen3.8-27B-8bit".
    /// Marker order matters: "eagle3" must be tried before "eagle".
    static func targetNameCandidates(from repoID: String) -> [String] {
        for marker in ["mtp", "eagle3", "eagle", "dflash"] {
            if let range = repoID.range(of: "-" + marker, options: .caseInsensitive) {
                var candidate = repoID
                candidate.removeSubrange(range)
                return [candidate]
            }
        }
        return []
    }
}

struct LocalModelMemoryEstimate: Equatable, Sendable {
    static let headroomFraction = 0.20

    /// Coarse peak-activation reserve for image-generation pipelines. Diffusion
    /// activation memory (attention + VAE decode) is roughly dtype-independent
    /// and grows with resolution, so a weights-only estimate green-lights
    /// pipelines that OOM at generation. Starting constant — refine per family
    /// and output resolution later.
    static let imageGenerationActivationReserveBytes: UInt64 = 6 * 1024 * 1024 * 1024

    static func activationReserveBytes(for capabilities: Set<LocalModelCapability>) -> UInt64 {
        capabilities.contains(.imageGeneration)
            || capabilities.contains(.imageEditing)
            ? imageGenerationActivationReserveBytes
            : 0
    }

    let estimatedModelBytes: UInt64
    let memoryBudgetBytes: UInt64
    let totalMemoryBytes: UInt64
    var activationReserveBytes: UInt64 = 0

    /// Resident weights plus any peak-activation reserve, saturating on overflow.
    var workingSetBytes: UInt64 {
        let sum = estimatedModelBytes.addingReportingOverflow(activationReserveBytes)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    var isUsable: Bool {
        workingSetBytes <= memoryBudgetBytes
    }

    var compatibilityLabel: String {
        isUsable ? "Likely fits in memory" : "May not fit in memory"
    }

    var explanation: String {
        let estimated = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: estimatedModelBytes),
            countStyle: .memory
        )
        let budget = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: memoryBudgetBytes),
            countStyle: .memory
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: totalMemoryBytes),
            countStyle: .memory
        )
        let headroomPercent = Int((Self.headroomFraction * 100).rounded())
        if activationReserveBytes > 0 {
            let reserve = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: activationReserveBytes),
                countStyle: .memory
            )
            return "Estimated weights: \(estimated), plus ~\(reserve) peak activation for image generation. Usable budget: \(budget) of \(total) unified memory, reserving \(headroomPercent)% for KV cache and runtime headroom."
        }
        return "Estimated model memory: \(estimated). Usable budget: \(budget) of \(total) unified memory, reserving \(headroomPercent)% for KV cache and runtime headroom."
    }
}

struct LocalModelConfigurationMetadata: Equatable, Sendable {
    let contextSize: Int?
    let defaultSystemPrompt: String?
    let hiddenSize: Int?
}

enum LocalModelDiscovery {
    private actor ScanCache {
        struct Key: Hashable, Sendable {
            let path: String
            let additionalPaths: [String]
        }

        private struct Entry: Sendable {
            let models: [LocalModel]
            let expiresAt: Date
        }

        private var entries: [Key: Entry] = [:]
        private var inFlight: [Key: Task<[LocalModel], Error>] = [:]

        func scan(key: Key) async throws -> [LocalModel] {
            let now = Date()
            entries = entries.filter { $0.value.expiresAt > now }
            if let entry = entries[key] {
                return entry.models
            }

            if let task = inFlight[key] {
                return try await task.value
            }

            let task = Task.detached(priority: .userInitiated) {
                try LocalModelDiscovery.performScan(
                    path: key.path,
                    additionalPaths: key.additionalPaths
                )
            }
            inFlight[key] = task

            do {
                let models = try await task.value
                entries[key] = Entry(
                    models: models,
                    expiresAt: Date().addingTimeInterval(2)
                )
                inFlight.removeValue(forKey: key)
                return models
            } catch {
                inFlight.removeValue(forKey: key)
                throw error
            }
        }
    }

    private static let scanCache = ScanCache()

    static func scan(searchPaths: LocalModelSearchPaths) async throws -> [LocalModel] {
        return try await scanCache.scan(
            key: ScanCache.Key(
                path: searchPaths.primary,
                additionalPaths: searchPaths.additional
            )
        )
    }

    private static func performScan(
        path: String,
        additionalPaths: [String]
    ) throws -> [LocalModel] {
        let externalModels = Self.scanAdditionalPathsSynchronously(
            additionalPaths,
            fileManager: FileManager.default
        )
        do {
            return Self.sortedByDisplayName(try Self.scanSynchronously(path: path) + externalModels)
        } catch {
            guard !externalModels.isEmpty else {
                throw error
            }
            return Self.sortedByDisplayName(externalModels)
        }
    }

    static func delete(repoID: String, path: String) async throws {
        let expandedPath = Self.expandedPath(path)
        try await Task.detached(priority: .utility) {
            let directoryName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
            let cacheURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
            let fileManager = FileManager.default
            let repositoryURL = cacheURL.appendingPathComponent(directoryName, isDirectory: true)
            let lockURL = cacheURL
                .appendingPathComponent(".locks", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)

            if fileManager.fileExists(atPath: repositoryURL.path) {
                try fileManager.removeItem(at: repositoryURL)
            }
            if fileManager.fileExists(atPath: lockURL.path) {
                try fileManager.removeItem(at: lockURL)
            }
        }.value
    }

    static func configurationMetadata(
        repoID: String,
        path: String
    ) async -> LocalModelConfigurationMetadata? {
        let expandedPath = Self.expandedPath(path)
        return await Task.detached(priority: .userInitiated) {
            Self.configurationMetadataSynchronously(
                repoID: repoID,
                path: expandedPath
            )
        }.value
    }

    static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePath = trimmed.isEmpty ? NativSettings.defaultModelSearchPath : trimmed
        return (effectivePath as NSString).expandingTildeInPath
    }

    private static func scanSynchronously(path: String) throws -> [LocalModel] {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw LocalModelDiscoveryError.pathNotFound(path)
        }
        guard isDirectory.boolValue else {
            throw LocalModelDiscoveryError.notDirectory(path)
        }

        let repoURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let models = repoURLs.compactMap { repoURL -> LocalModel? in
            guard repoURL.lastPathComponent.hasPrefix("models--"),
                  isDirectoryURL(repoURL, fileManager: fileManager),
                  let repoID = repoID(fromCacheDirectoryName: repoURL.lastPathComponent)
            else {
                return nil
            }

            guard let snapshotURL = preferredSnapshotURL(for: repoURL, fileManager: fileManager),
                  isLikelyMLXModelSnapshot(snapshotURL, model: repoID, fileManager: fileManager)
            else {
                return nil
            }

            let modifiedAt = (try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let memoryMetadata = modelMemoryMetadata(
                repoID: repoID,
                snapshotURL: snapshotURL,
                fileManager: fileManager
            )
            let speculativeMetadata = speculativeMetadata(
                at: snapshotURL,
                fileManager: fileManager
            )
            return LocalModel(
                repoID: repoID,
                snapshotURL: snapshotURL,
                modifiedAt: modifiedAt,
                sizeBytes: snapshotSize(at: snapshotURL, fileManager: fileManager),
                parameterCount: memoryMetadata.parameterCount,
                quantizationBits: memoryMetadata.quantizationBits,
                quantizationGroupSize: memoryMetadata.quantizationGroupSize,
                contextSize: contextSize(at: snapshotURL, fileManager: fileManager),
                provider: modelProvider(
                    repoID: repoID,
                    snapshotURL: snapshotURL,
                    fileManager: fileManager
                ),
                capabilities: modelCapabilities(
                    model: repoID,
                    at: snapshotURL,
                    fileManager: fileManager
                ),
                drafterKind: speculativeMetadata.drafterKind,
                hiddenSize: speculativeMetadata.hiddenSize
            )
        }

        return models
    }

    private static func sortedByDisplayName(_ models: [LocalModel]) -> [LocalModel] {
        models.sorted { lhs, rhs in
            switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.repoID < rhs.repoID
            }
        }
    }

    private static func scanAdditionalPathsSynchronously(
        _ rootPaths: [String],
        fileManager: FileManager
    ) -> [LocalModel] {
        var models: [LocalModel] = []
        var seenPaths = Set<String>()

        for rootPath in rootPaths {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard isDirectoryURL(rootURL, fileManager: fileManager) else {
                continue
            }

            if isLikelyMLXModelSnapshot(rootURL, fileManager: fileManager) {
                if let model = externalModel(at: rootURL, fileManager: fileManager, seenPaths: &seenPaths) {
                    models.append(model)
                }
                continue
            }

            for childURL in directoryContents(of: rootURL, fileManager: fileManager) {
                if isLikelyMLXModelSnapshot(childURL, fileManager: fileManager) {
                    if let model = externalModel(at: childURL, fileManager: fileManager, seenPaths: &seenPaths) {
                        models.append(model)
                    }
                    continue
                }

                for grandchildURL in directoryContents(of: childURL, fileManager: fileManager)
                where isLikelyMLXModelSnapshot(grandchildURL, fileManager: fileManager) {
                    if let model = externalModel(at: grandchildURL, fileManager: fileManager, seenPaths: &seenPaths) {
                        models.append(model)
                    }
                }
            }
        }
        return models
    }

    private static func directoryContents(of url: URL, fileManager: FileManager) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { isDirectoryURL($0, fileManager: fileManager) }
    }

    private static func externalModel(
        at modelURL: URL,
        fileManager: FileManager,
        seenPaths: inout Set<String>
    ) -> LocalModel? {
        let standardizedPath = modelURL.standardizedFileURL.path
        guard seenPaths.insert(standardizedPath).inserted else {
            return nil
        }

        let hubStyleID = modelURL.standardizedFileURL.pathComponents.suffix(2).joined(separator: "/")
        let modifiedAt = (try? modelURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let memoryMetadata = modelMemoryMetadata(
            repoID: hubStyleID,
            snapshotURL: modelURL,
            fileManager: fileManager
        )
        let speculativeMetadata = speculativeMetadata(
            at: modelURL,
            fileManager: fileManager
        )
        return LocalModel(
            repoID: standardizedPath,
            snapshotURL: modelURL,
            modifiedAt: modifiedAt,
            sizeBytes: snapshotSize(at: modelURL, fileManager: fileManager),
            parameterCount: memoryMetadata.parameterCount,
            quantizationBits: memoryMetadata.quantizationBits,
            quantizationGroupSize: memoryMetadata.quantizationGroupSize,
            contextSize: contextSize(at: modelURL, fileManager: fileManager),
            provider: modelProvider(
                repoID: hubStyleID,
                snapshotURL: modelURL,
                fileManager: fileManager
            ),
            capabilities: modelCapabilities(
                model: standardizedPath,
                at: modelURL,
                fileManager: fileManager
            ),
            drafterKind: speculativeMetadata.drafterKind,
            hiddenSize: speculativeMetadata.hiddenSize,
            source: .external
        )
    }

    static let speechToTextModelTypesRequiringPreprocessor: Set<String> = [
        "mms",
        "moss_transcribe_diarize",
        "qwen2_audio",
        "qwen3_asr",
        "voxtral"
    ]

    static func speechToTextPreloadIssue(repoID: String, path: String) -> String? {
        let fileManager = FileManager.default
        guard let snapshotURL = modelSnapshotURL(
            repoID: repoID,
            path: expandedPath(path),
            fileManager: fileManager
        ) else {
            return nil
        }

        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = (config["model_type"] as? String)?.lowercased(),
              speechToTextModelTypesRequiringPreprocessor.contains(modelType)
        else {
            return nil
        }

        let preprocessorURL = snapshotURL.appendingPathComponent("preprocessor_config.json")
        guard !fileManager.fileExists(atPath: preprocessorURL.path) else {
            return nil
        }

        return "\(repoID) is missing preprocessor_config.json, which \(modelType) speech models need in order to load."
    }

    private static func modelSnapshotURL(
        repoID: String,
        path: String,
        fileManager: FileManager
    ) -> URL? {
        if repoID.hasPrefix("/") {
            let directURL = URL(fileURLWithPath: repoID, isDirectory: true)
            return isDirectoryURL(directURL, fileManager: fileManager) ? directURL : nil
        }

        let repositoryName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(repositoryName, isDirectory: true)
        return preferredSnapshotURL(for: repositoryURL, fileManager: fileManager)
    }

    private static func configurationMetadataSynchronously(
        repoID: String,
        path: String
    ) -> LocalModelConfigurationMetadata? {
        let fileManager = FileManager.default

        if repoID.hasPrefix("/") {
            let directURL = URL(fileURLWithPath: repoID, isDirectory: true)
            guard isDirectoryURL(directURL, fileManager: fileManager) else {
                return nil
            }
            return LocalModelConfigurationMetadata(
                contextSize: contextSizeFromConfig(at: directURL, fileManager: fileManager),
                defaultSystemPrompt: defaultSystemPrompt(at: directURL, fileManager: fileManager),
                hiddenSize: speculativeMetadata(at: directURL, fileManager: fileManager).hiddenSize
            )
        }

        let repositoryName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(repositoryName, isDirectory: true)

        guard let snapshotURL = preferredSnapshotURL(
            for: repositoryURL,
            fileManager: fileManager
        ) else {
            return nil
        }

        return LocalModelConfigurationMetadata(
            contextSize: contextSizeFromConfig(
                at: snapshotURL,
                fileManager: fileManager
            ),
            defaultSystemPrompt: defaultSystemPrompt(
                at: snapshotURL,
                fileManager: fileManager
            ),
            hiddenSize: speculativeMetadata(
                at: snapshotURL,
                fileManager: fileManager
            ).hiddenSize
        )
    }

    private static func repoID(fromCacheDirectoryName name: String) -> String? {
        let prefix = "models--"
        guard name.hasPrefix(prefix) else {
            return nil
        }

        let encoded = String(name.dropFirst(prefix.count))
        let parts = encoded.components(separatedBy: "--").filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return nil
        }
        return parts.joined(separator: "/")
    }

    private static func preferredSnapshotURL(for repoURL: URL, fileManager: FileManager) -> URL? {
        if let mainRef = readRef(named: "main", repoURL: repoURL, fileManager: fileManager) {
            let snapshotURL = repoURL
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(mainRef, isDirectory: true)
            if isDirectoryURL(snapshotURL, fileManager: fileManager) {
                return snapshotURL
            }
        }

        let snapshotsURL = repoURL.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURLs = try? fileManager.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return snapshotURLs
            .filter { isDirectoryURL($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private static func readRef(named name: String, repoURL: URL, fileManager: FileManager) -> String? {
        let refURL = repoURL
            .appendingPathComponent("refs", isDirectory: true)
            .appendingPathComponent(name)
        guard fileManager.fileExists(atPath: refURL.path),
              let contents = try? String(contentsOf: refURL, encoding: .utf8)
        else {
            return nil
        }

        let ref = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.isEmpty ? nil : ref
    }

    private static func isLikelyMLXModelSnapshot(_ snapshotURL: URL, model: String = "", fileManager: FileManager) -> Bool {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        let tokenizerConfigURL = snapshotURL.appendingPathComponent("tokenizer_config.json")
        let modelIndexURL = snapshotURL.appendingPathComponent("model_index.json")
        guard fileManager.fileExists(atPath: configURL.path) || fileManager.fileExists(atPath: tokenizerConfigURL.path) || fileManager.fileExists(atPath: modelIndexURL.path)
        else {
            return false
        }

        switch safetensorsShardIndexStatus(at: snapshotURL, fileManager: fileManager) {
        case .complete:
            return true
        case .incomplete:
            return false
        case .absent:
            break
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        if contents.contains(where: { $0.pathExtension == "safetensors" }) {
            return true
        }

        // Image-generation pipelines commonly store weights in component
        // directories rather than at the snapshot root. Let the generated
        // backend manifest and its family-specific layout checks decide
        // whether such a snapshot is complete and loadable.
        return MLXImageModelResolver.shared.isSupportedImageModel(
            model: model,
            at: snapshotURL,
            fileManager: fileManager
        )
    }

    private enum SafetensorsShardIndexStatus {
        case absent
        case complete
        case incomplete
    }

    private struct SafetensorsShardIndex: Decodable {
        let weightMap: [String: String]

        private enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    /// A shard index is downloaded before the weight shards it describes. Treat
    /// the snapshot as usable only after every referenced shard is a non-empty
    /// regular file inside the snapshot directory.
    private static func safetensorsShardIndexStatus(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> SafetensorsShardIndexStatus {
        let indexURL = snapshotURL.appendingPathComponent("model.safetensors.index.json")
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return .absent
        }

        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(SafetensorsShardIndex.self, from: data)
        else {
            return .incomplete
        }

        let shardFilenames = Set(index.weightMap.values)
        guard !shardFilenames.isEmpty else {
            return .incomplete
        }

        let snapshotPath = snapshotURL.standardizedFileURL.path
        let snapshotPrefix = snapshotPath.hasSuffix("/") ? snapshotPath : snapshotPath + "/"
        let allShardsAreAvailable = shardFilenames.allSatisfy { filename in
            guard !filename.isEmpty,
                  !(filename as NSString).isAbsolutePath
            else {
                return false
            }

            let shardURL = snapshotURL.appendingPathComponent(filename).standardizedFileURL
            guard shardURL.path.hasPrefix(snapshotPrefix),
                  let values = try? shardURL.resolvingSymlinksInPath().resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0
            else {
                return false
            }
            return true
        }
        return allShardsAreAvailable ? .complete : .incomplete
    }

    private static func snapshotSize(at snapshotURL: URL, fileManager: FileManager) -> Int64? {
        guard let enumerator = fileManager.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var visitedFiles = Set<String>()
        var totalBytes: Int64 = 0
        var foundFile = false

        for case let fileURL as URL in enumerator {
            let resolvedURL = fileURL.resolvingSymlinksInPath()
            guard visitedFiles.insert(resolvedURL.path).inserted,
                  let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize
            else {
                continue
            }
            totalBytes += Int64(fileSize)
            foundFile = true
        }

        return foundFile ? totalBytes : nil
    }

    private struct ModelMemoryMetadata {
        let parameterCount: Int64?
        let quantizationBits: Int?
        let quantizationGroupSize: Int?
    }

    private static func modelMemoryMetadata(
        repoID: String,
        snapshotURL: URL,
        fileManager: FileManager
    ) -> ModelMemoryMetadata {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        let config: [String: Any]? = if fileManager.fileExists(atPath: configURL.path),
                                       let data = try? Data(contentsOf: configURL) {
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            nil
        }

        let quantization = (config?["quantization"] as? [String: Any])
            ?? (config?["quantization_config"] as? [String: Any])
        let parameterCount = integer64Value(config?["num_parameters"])
            ?? integer64Value(config?["parameter_count"])
            ?? parameterCount(from: repoID)
        let quantizationBits = integerValue(quantization?["bits"])
            ?? integerValue(quantization?["nbits"])
            ?? quantizationBits(from: repoID)
        let quantizationGroupSize = integerValue(quantization?["group_size"])

        return ModelMemoryMetadata(
            parameterCount: parameterCount,
            quantizationBits: quantizationBits,
            quantizationGroupSize: quantizationGroupSize
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func integer64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    static func parameterCount(from repoID: String) -> Int64? {
        firstNumericModelDescriptor(
            in: repoID,
            pattern: #"(?i)(?:^|[/_-])(\d+(?:\.\d+)?)\s*([bm])(?:$|[/_-])"#
        ) { value, suffix in
            let multiplier = suffix.lowercased() == "b" ? 1_000_000_000.0 : 1_000_000.0
            let result = value * multiplier
            guard result.isFinite, result > 0, result <= Double(Int64.max) else {
                return nil
            }
            return Int64(result.rounded())
        }
    }

    static func quantizationBits(from repoID: String) -> Int? {
        firstNumericModelDescriptor(
            in: repoID,
            pattern: #"(?i)(?:^|[/_-])(\d+(?:\.\d+)?)\s*-?bits?(?:$|[/_-])"#
        ) { value, _ in
            let bits = Int(value.rounded())
            return (2...16).contains(bits) ? bits : nil
        }
    }

    private static func firstNumericModelDescriptor<Result>(
        in value: String,
        pattern: String,
        transform: (Double, String) -> Result?
    ) -> Result? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let numberRange = Range(match.range(at: 1), in: value),
              let number = Double(value[numberRange])
        else {
            return nil
        }

        let suffix: String
        if match.numberOfRanges > 2,
           let suffixRange = Range(match.range(at: 2), in: value) {
            suffix = String(value[suffixRange])
        } else {
            suffix = ""
        }
        return transform(number, suffix)
    }

    private static func contextSize(at snapshotURL: URL, fileManager: FileManager) -> Int? {
        let candidates = ["config.json", "tokenizer_config.json"]
        for filename in candidates {
            let url = snapshotURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contextSize = contextSize(in: json)
            else {
                continue
            }
            return contextSize
        }
        return nil
    }

    private static func contextSizeFromConfig(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> Int? {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return contextSize(in: config)
    }

    private static func defaultSystemPrompt(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> String? {
        var templates: [String] = []
        let templateURL = snapshotURL.appendingPathComponent("chat_template.jinja")
        if fileManager.fileExists(atPath: templateURL.path),
           let template = try? String(contentsOf: templateURL, encoding: .utf8) {
            templates.append(template)
        }

        for filename in ["tokenizer_config.json", "processor_config.json"] {
            let metadataURL = snapshotURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: metadataURL.path),
                  let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            for key in ["default_system_prompt", "default_system_message"] {
                if let prompt = normalizedSystemPrompt(metadata[key] as? String) {
                    return prompt
                }
            }
            if let chatTemplate = metadata["chat_template"] {
                templates.append(contentsOf: templateStrings(in: chatTemplate))
            }
        }

        return templates.lazy.compactMap(defaultSystemPrompt(in:)).first
    }

    private static func templateStrings(in value: Any) -> [String] {
        if let template = value as? String {
            return [template]
        }
        if let values = value as? [Any] {
            return values.flatMap(templateStrings(in:))
        }
        if let values = value as? [String: Any] {
            return values.values.flatMap(templateStrings(in:))
        }
        return []
    }

    private static func defaultSystemPrompt(in template: String) -> String? {
        let assignmentPatterns = [
            #"(?is)\{%-?\s*set\s+(?:default_)?system_(?:prompt|message)\s*=\s*'((?:\\.|[^'\\])*)'\s*-?%\}"#,
            #"(?is)\{%-?\s*set\s+(?:default_)?system_(?:prompt|message)\s*=\s*\"((?:\\.|[^\"\\])*)\"\s*-?%\}"#
        ]
        for pattern in assignmentPatterns {
            for value in regexCaptures(pattern: pattern, text: template) {
                if let prompt = normalizedSystemPrompt(unescapedTemplateLiteral(value)) {
                    return prompt
                }
            }
        }

        let literalPatterns = [
            #"'((?:\\.|[^'\\])*)'"#,
            #"\"((?:\\.|[^\"\\])*)\""#
        ]
        for pattern in literalPatterns {
            for value in regexCaptures(pattern: pattern, text: template) {
                let literal = unescapedTemplateLiteral(value)
                if let prompt = systemPromptFromRenderedLiteral(literal) {
                    return prompt
                }
            }
        }
        return nil
    }

    private static func regexCaptures(pattern: String, text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private static func unescapedTemplateLiteral(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let nextIndex = value.index(after: index)
            guard nextIndex < value.endIndex else {
                result.append(character)
                break
            }
            switch value[nextIndex] {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            case "'": result.append("'")
            case "\"": result.append("\"")
            default:
                result.append("\\")
                result.append(value[nextIndex])
            }
            index = value.index(after: nextIndex)
        }
        return result
    }

    private static func systemPromptFromRenderedLiteral(_ literal: String) -> String? {
        let boundaries = [
            ("<|im_start|>system\n", "<|im_end|>"),
            ("<|start_header_id|>system<|end_header_id|>\n\n", "<|eot_id|>"),
            ("<|turn>system\n", "<turn|>"),
            ("<<SYS>>\n", "\n<</SYS>>")
        ]

        for (prefix, suffix) in boundaries {
            guard let prefixRange = literal.range(of: prefix) else {
                continue
            }
            let remainder = literal[prefixRange.upperBound...]
            guard let suffixRange = remainder.range(of: suffix) else {
                continue
            }
            if let prompt = normalizedSystemPrompt(String(remainder[..<suffixRange.lowerBound])) {
                return prompt
            }
        }
        return nil
    }

    private static func normalizedSystemPrompt(_ prompt: String?) -> String? {
        guard let prompt else {
            return nil
        }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 20_000,
              !normalized.contains("{{"),
              !normalized.contains("{%")
        else {
            return nil
        }
        return normalized
    }

    private static func modelCapabilities(
        model: String,
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> Set<LocalModelCapability> {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        let config: [String: Any]
        if fileManager.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let parsedConfig = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsedConfig
        } else {
            config = [:]
        }

        let modelIndexURL = snapshotURL.appendingPathComponent("model_index.json")
        let modelIndex: [String: Any]
        if fileManager.fileExists(atPath: modelIndexURL.path),
           let data = try? Data(contentsOf: modelIndexURL),
           let parsedModelIndex = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            modelIndex = parsedModelIndex
        } else {
            modelIndex = [:]
        }

        let keys = recursiveKeys(in: config).union(recursiveKeys(in: modelIndex))
        let descriptors = [modelDescriptors(in: config), modelDescriptors(in: modelIndex)]
            .joined(separator: " ")
        let primaryTask = ModelPrimaryTaskResolver.resolve(
            model: model,
            config: config
        )
        var capabilities = Set<LocalModelCapability>()

        if drafterKind(fromModelType: drafterModelType(in: config)) != nil {
            capabilities.insert(.drafter)
        }

        let textDescriptors = [
            "causallm", "conditionalgeneration", "language", "llm", "gpt",
            "gemma", "qwen", "mistral", "llama", "deepseek", "cohere"
        ]
        let generativeArchitectures = ["forcausallm", "forconditionalgeneration", "lmheadmodel"]
        if primaryTask.includesLanguageCapability(
            fallbackMatch: textDescriptors.contains(where: descriptors.contains)
                || generativeArchitectures.contains(where: descriptors.contains)
        ) {
            capabilities.insert(.text)
        }

        switch primaryTask {
        case .textToSpeech:
            capabilities.formUnion([.audio, .textToSpeech])
        case .speechToText:
            capabilities.formUnion([.audio, .speechToText])
        case .language, .audioLanguage, .unknown:
            break
        }

        let visionKeys: Set<String> = [
            "vision_config",
            "vision_tower",
            "vit_config",
            "img_processor",
            "image_token_id",
            "image_start_token_id"
        ]
        let visionDescriptors = [
            "vision", "llava", "pixtral", "minicpmv", "molmo", "phi3_v", "omni"
        ]
        if !keys.isDisjoint(with: visionKeys)
            || visionDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.vision)
        }

        let videoDescriptors = ["video", "videollava"]
        if videoDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.video)
            capabilities.insert(.vision)
        }

        if MLXImageModelResolver.shared.isImageGenerationModel(
            model: model,
            at: snapshotURL,
            fileManager: fileManager
        ) {
            capabilities.insert(.imageGeneration)
        }
        if MLXImageModelResolver.shared.isImageEditingModel(
            model: model,
            at: snapshotURL,
            fileManager: fileManager
        ) {
            capabilities.insert(.imageEditing)
        }

        let audioKeys: Set<String> = [
            "audio_config",
            "audio_decoder_config",
            "audio_encoder_config",
            "audio_tokenizer_config",
            "audio_tower",
            "audio_token_id",
            "speech_config",
            "max_audio_clip_s",
            "sample_rate",
            "code2wav_config",
            "speaker_encoder_config",
            "tts_model_type"
        ]
        let audioDescriptors = [
            "audio", "speech", "whisper", "asr", "tts", "transcribe", "omni"
        ]
        if !keys.isDisjoint(with: audioKeys)
            || audioDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.audio)
        }

        let speechToTextDescriptors = ["whisper", "asr", "transcribe", "speechrecognition"]
        if speechToTextDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.speechToText)
        }

        let textToSpeechDescriptors = ["tts", "texttospeech", "speechsynthesis"]
        if textToSpeechDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.textToSpeech)
        }

        if let embeddingStamp = config["mlx_embeddings"] as? [String: Any],
            (embeddingStamp["kind"] as? String) == "embedding" {
            if (embeddingStamp["modality"] as? String) != "vision" {
                capabilities.insert(.embeddings)
            }
        } else {
            let embeddingModelType = ((config["model_type"] as? String) ?? "")
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            let textEmbeddingModelTypes: Set<String> = [
                "bert", "modernbert", "xlm_roberta", "llama_bidirec"
            ]
            let hasSentenceTransformerLayout =
                fileManager.fileExists(atPath: snapshotURL.appendingPathComponent("modules.json").path)
                || fileManager.fileExists(atPath: snapshotURL.appendingPathComponent("1_Pooling/config.json").path)
                || fileManager.fileExists(atPath: snapshotURL.appendingPathComponent("sentence_bert_config.json").path)
            let isEmbeddingModel =
                hasSentenceTransformerLayout
                || (!generativeArchitectures.contains(where: descriptors.contains)
                    && (textEmbeddingModelTypes.contains(embeddingModelType)
                        || descriptors.contains("embedding")))
            if isEmbeddingModel && !capabilities.contains(.vision) {
                capabilities.insert(.embeddings)
            }
        }

        if model.localizedCaseInsensitiveContains("rerank")
            || descriptors.contains("reranker")
            || descriptors.contains("reranking") {
            capabilities.insert(.reranking)
        }

        if capabilities.contains(.text)
            && (descriptors.contains("reasoning")
                || descriptors.contains("thinking")
                || keys.contains("thinking_config")
                || supportsThinkingMode(
                    at: snapshotURL,
                    fileManager: fileManager
                )) {
            capabilities.insert(.reasoning)
        }

        if capabilities.contains(.text)
            && supportsToolCalling(
                at: snapshotURL,
                fileManager: fileManager
            ) {
            capabilities.insert(.tools)
        }

        return capabilities
    }

    private static func supportsThinkingMode(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let templateURL = snapshotURL.appendingPathComponent("chat_template.jinja")
        if fileManager.fileExists(atPath: templateURL.path),
           let template = try? String(contentsOf: templateURL, encoding: .utf8),
           containsThinkingMarkers(template) {
            return true
        }

        for filename in ["tokenizer_config.json", "processor_config.json"] {
            let metadataURL = snapshotURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: metadataURL.path),
                  let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chatTemplate = metadata["chat_template"]
            else {
                continue
            }
            if templateContainsThinkingMarkers(chatTemplate) {
                return true
            }
        }

        return false
    }

    private static func templateContainsThinkingMarkers(_ value: Any) -> Bool {
        if let template = value as? String {
            return containsThinkingMarkers(template)
        }
        if let templates = value as? [Any] {
            return templates.contains(where: templateContainsThinkingMarkers)
        }
        if let templates = value as? [String: Any] {
            return templates.values.contains(where: templateContainsThinkingMarkers)
        }
        return false
    }

    private static func containsThinkingMarkers(_ template: String) -> Bool {
        let normalized = template.lowercased()
        let markers = [
            "enable_thinking",
            "thinking_config",
            "reasoning_content",
            "reasoning_prompt",
            "thought_instructions",
            "<think>",
            "</think>",
            "<thinking>",
            "</thinking>"
        ]
        return markers.contains(where: normalized.contains)
    }

    private static func supportsToolCalling(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let templateURL = snapshotURL.appendingPathComponent("chat_template.jinja")
        if fileManager.fileExists(atPath: templateURL.path),
           let template = try? String(contentsOf: templateURL, encoding: .utf8),
           containsToolCallingMarkers(template) {
            return true
        }

        for filename in ["tokenizer_config.json", "processor_config.json"] {
            let metadataURL = snapshotURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: metadataURL.path),
                  let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chatTemplate = metadata["chat_template"]
            else {
                continue
            }
            if templateContainsToolCallingMarkers(chatTemplate) {
                return true
            }
        }

        return false
    }

    private static func templateContainsToolCallingMarkers(_ value: Any) -> Bool {
        if let template = value as? String {
            return containsToolCallingMarkers(template)
        }
        if let templates = value as? [Any] {
            return templates.contains(where: templateContainsToolCallingMarkers)
        }
        if let templates = value as? [String: Any] {
            return templates.values.contains(where: templateContainsToolCallingMarkers)
        }
        return false
    }

    private static func containsToolCallingMarkers(_ template: String) -> Bool {
        let normalized = template.lowercased()
        return normalized.contains("tool_calls") || normalized.contains("tool_call")
    }

    static func drafterKind(fromModelType modelType: String?) -> String? {
        guard let modelType = modelType?.lowercased(), !modelType.isEmpty else {
            return nil
        }
        let exactKinds: [String: String] = [
            "deepseek_v4_mtp": "mtp",
            "eagle3": "eagle3",
            "gemma4_assistant": "mtp",
            "gemma4_unified_assistant": "mtp",
            "glm4_moe_lite_mtp": "mtp",
            "inkling_mtp": "mtp",
            "qwen3_5_mtp": "mtp"
        ]
        if let kind = exactKinds[modelType] {
            return kind
        }
        if modelType.contains("mtp") {
            return "mtp"
        }
        if modelType.contains("dflash") {
            return "dflash"
        }
        if modelType.contains("eagle") {
            return "eagle3"
        }
        return nil
    }

    private static func drafterModelType(in config: [String: Any]) -> String? {
        (config["model_type"] as? String) ?? (config["speculators_model_type"] as? String)
    }

    private static func hiddenSize(in config: [String: Any]) -> Int? {
        for key in ["backbone_hidden_size", "target_hidden_size"] {
            if let number = config[key] as? NSNumber, number.intValue > 0 {
                return number.intValue
            }
        }
        for nestedKey in ["text_config", "llm_config", "language_config"] {
            if let nested = config[nestedKey] as? [String: Any],
               let number = nested["hidden_size"] as? NSNumber,
               number.intValue > 0 {
                return number.intValue
            }
        }
        if let number = config["hidden_size"] as? NSNumber, number.intValue > 0 {
            return number.intValue
        }
        return nil
    }

    private static func speculativeMetadata(
        at snapshotURL: URL,
        fileManager: FileManager
    ) -> (drafterKind: String?, hiddenSize: Int?) {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil)
        }
        return (
            drafterKind(fromModelType: drafterModelType(in: config)),
            hiddenSize(in: config)
        )
    }

    private static func modelProvider(
        repoID: String,
        snapshotURL: URL,
        fileManager: FileManager
    ) -> LocalModelProvider? {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LocalModelProviderResolver.resolve(
                repoID: repoID,
                modelType: nil,
                architectures: []
            )
        }

        return LocalModelProviderResolver.resolve(
            repoID: repoID,
            modelType: config["model_type"] as? String,
            architectures: config["architectures"] as? [String] ?? []
        )
    }

    private static func recursiveKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, entry in
                result.formUnion(recursiveKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, entry in
                result.formUnion(recursiveKeys(in: entry))
            }
        }
        return []
    }

    private static func modelDescriptors(in config: [String: Any]) -> String {
        let modelType = config["model_type"] as? String ?? ""
        let architectures = config["architectures"] as? [String] ?? []
        let className = config["_class_name"] as? String ?? ""
        let pipelineTag = config["pipeline_tag"] as? String ?? ""
        return ([modelType, className, pipelineTag] + architectures)
            .joined(separator: " ")
            .lowercased()
    }

    private static func contextSize(in config: [String: Any]) -> Int? {
        let nestedConfigurationKeys = ["text_config", "llm_config", "language_config"]
        let contextKeys = [
            "max_position_embeddings",
            "model_max_length",
            "max_sequence_length",
            "seq_length",
            "n_positions",
            "context_length"
        ]

        for nestedKey in nestedConfigurationKeys {
            if let nested = config[nestedKey] as? [String: Any],
               let value = contextValue(in: nested, keys: contextKeys) {
                return value
            }
        }
        return contextValue(in: config, keys: contextKeys)
    }

    private static func contextValue(in config: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let number = config[key] as? NSNumber else {
                continue
            }
            let value = number.intValue
            if value > 0, value <= 10_000_000 {
                return value
            }
        }
        return nil
    }

    private static func isDirectoryURL(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

extension LocalModelDiscovery {
    static func speechToTextModelID(
        in models: [LocalModel],
        selectedModelID: String?
    ) -> String? {
        let speechModels = models.filter {
            $0.capabilities.contains(.speechToText)
        }
        if let selectedModelID,
           speechModels.contains(where: { $0.repoID == selectedModelID }) {
            return selectedModelID
        }

        return speechModels.sorted {
            $0.repoID.localizedCaseInsensitiveCompare($1.repoID) == .orderedAscending
        }.first?.repoID
    }
}

enum LocalModelDiscoveryError: LocalizedError, Equatable {
    case pathNotFound(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound:
            return "Search path does not exist"
        case .notDirectory:
            return "Search path is not a folder"
        }
    }
}

@MainActor
final class LocalModelLibrary: ObservableObject {
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var isScanning = false
    @Published private(set) var deletingModelIDs = Set<String>()
    @Published private(set) var error: String?

    private var scanTask: Task<Void, Never>?

    deinit {
        scanTask?.cancel()
    }

    func scan(searchPaths: LocalModelSearchPaths) {
        scanTask?.cancel()
        isScanning = true
        error = nil

        scanTask = Task { [weak self] in
            do {
                let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
                guard !Task.isCancelled else {
                    return
                }
                self?.models = models
                self?.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.models = []
                self?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            guard !Task.isCancelled else {
                return
            }
            self?.isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func delete(
        model: LocalModel,
        path: String,
        onCompletion: @escaping () -> Void
    ) {
        guard !deletingModelIDs.contains(model.repoID) else { return }
        deletingModelIDs.insert(model.repoID)
        error = nil

        Task { [weak self] in
            do {
                try await LocalModelDiscovery.delete(repoID: model.repoID, path: path)
                self?.models.removeAll { $0.repoID == model.repoID }
                self?.deletingModelIDs.remove(model.repoID)
                onCompletion()
            } catch {
                self?.deletingModelIDs.remove(model.repoID)
                self?.error = "Couldn’t delete \(model.repoID): \(error.localizedDescription)"
            }
        }
    }
}
