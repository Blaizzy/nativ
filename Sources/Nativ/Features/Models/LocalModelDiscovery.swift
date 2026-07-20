import Foundation

extension Notification.Name {
    static let localModelLibraryDidChange = Notification.Name("LocalModelLibraryDidChange")
}

enum LocalModelCapability: String, CaseIterable, Hashable, Sendable {
    case text
    case vision
    case audio
    case video
    case imageGeneration
    case speechToText
    case textToSpeech
    case embeddings
    case reasoning
    case tools

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
            "Image generation"
        case .speechToText:
            "Speech to text"
        case .textToSpeech:
            "Text to speech"
        case .embeddings:
            "Embeddings"
        case .reasoning:
            "Reasoning"
        case .tools:
            "Tool calling"
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

    var isEligibleForLanguageModelPicker: Bool {
        !capabilities.contains(.speechToText)
            && !capabilities.contains(.textToSpeech)
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
            totalMemoryBytes: totalMemoryBytes
        )
    }

    private static func compactCount(_ value: Double, suffix: String) -> String {
        if value.rounded() == value {
            return "\(Int(value))\(suffix)"
        }
        return String(format: "%.1f%@", value, suffix)
    }
}

struct LocalModelMemoryEstimate: Equatable, Sendable {
    static let headroomFraction = 0.20

    let estimatedModelBytes: UInt64
    let memoryBudgetBytes: UInt64
    let totalMemoryBytes: UInt64

    var isUsable: Bool {
        estimatedModelBytes <= memoryBudgetBytes
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
        return "Estimated model memory: \(estimated). Usable budget: \(budget) of \(total) unified memory, reserving \(headroomPercent)% for KV cache and runtime headroom."
    }
}

struct LocalModelConfigurationMetadata: Equatable, Sendable {
    let contextSize: Int?
    let defaultSystemPrompt: String?
}

enum LocalModelDiscovery {
    static func scan(path: String) async throws -> [LocalModel] {
        let expandedPath = Self.expandedPath(path)
        return try await Task.detached(priority: .userInitiated) {
            try Self.scanSynchronously(path: expandedPath)
        }.value
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
                  isLikelyMLXModelSnapshot(snapshotURL, fileManager: fileManager)
            else {
                return nil
            }

            let modifiedAt = (try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let memoryMetadata = modelMemoryMetadata(
                repoID: repoID,
                snapshotURL: snapshotURL,
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
                capabilities: modelCapabilities(at: snapshotURL, fileManager: fileManager)
            )
        }

        return models.sorted { lhs, rhs in
            switch lhs.repoID.localizedCaseInsensitiveCompare(rhs.repoID) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.repoID < rhs.repoID
            }
        }
    }

    private static func configurationMetadataSynchronously(
        repoID: String,
        path: String
    ) -> LocalModelConfigurationMetadata? {
        let fileManager = FileManager.default
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
            )
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

    private static func isLikelyMLXModelSnapshot(_ snapshotURL: URL, fileManager: FileManager) -> Bool {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        let tokenizerConfigURL = snapshotURL.appendingPathComponent("tokenizer_config.json")
        let modelIndexURL = snapshotURL.appendingPathComponent("model_index.json")
        guard fileManager.fileExists(atPath: configURL.path) || fileManager.fileExists(atPath: tokenizerConfigURL.path) || fileManager.fileExists(atPath: modelIndexURL.path)
        else {
            return false
        }

        let indexURL = snapshotURL.appendingPathComponent("model.safetensors.index.json")
        if fileManager.fileExists(atPath: indexURL.path) {
            return true
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.contains { $0.pathExtension == "safetensors" }
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
        var capabilities = Set<LocalModelCapability>()

        let textDescriptors = [
            "causallm", "conditionalgeneration", "language", "llm", "gpt",
            "gemma", "qwen", "mistral", "llama", "deepseek", "cohere"
        ]
        if textDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.text)
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

        let imageGenerationDescriptors = [
            "diffusion", "stable_diffusion", "fluxpipeline", "imagegeneration"
        ]
        if imageGenerationDescriptors.contains(where: descriptors.contains) {
            capabilities.insert(.imageGeneration)
        }

        let audioKeys: Set<String> = [
            "audio_config",
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

        if fileManager.fileExists(atPath: snapshotURL.appendingPathComponent("modules.json").path)
            || descriptors.contains("embedding") {
            capabilities.insert(.embeddings)
        }

        if descriptors.contains("reasoning")
            || descriptors.contains("thinking")
            || keys.contains("thinking_config")
            || supportsThinkingMode(at: snapshotURL, fileManager: fileManager) {
            capabilities.insert(.reasoning)
        }

        if supportsToolCalling(at: snapshotURL, fileManager: fileManager) {
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

    func scan(path: String) {
        scanTask?.cancel()
        isScanning = true
        error = nil

        scanTask = Task { [weak self] in
            do {
                let models = try await LocalModelDiscovery.scan(path: path)
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
