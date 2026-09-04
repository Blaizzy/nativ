import Combine
import Darwin
import Foundation
import NativServerKit

enum HuggingFaceModelSort: String, CaseIterable, Hashable, Identifiable, Sendable {
    case downloads
    case trending = "trendingScore"
    case likes
    case recentlyUpdated = "lastModified"
    case size

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .trending: "Trending"
        case .likes: "Likes"
        case .recentlyUpdated: "Recently Updated"
        case .size: "Size"
        }
    }

    var systemImage: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .trending: "flame"
        case .likes: "heart"
        case .recentlyUpdated: "clock.arrow.circlepath"
        case .size: "internaldrive"
        }
    }

    var hubWebValue: String {
        switch self {
        case .downloads: "downloads"
        case .trending: "trending"
        case .likes: "likes"
        case .recentlyUpdated: "modified"
        case .size: "downloads"
        }
    }

    /// Whether results are re-sorted client-side by model size.
    var sortsBySize: Bool { self == .size }

    var apiSortValue: String {
        self == .size ? "downloads" : rawValue
    }
}

enum HuggingFaceSortDirection: Int, CaseIterable, Hashable, Identifiable, Sendable {
    case descending = -1
    case ascending = 1

    var id: Int { rawValue }
    var apiValue: String { String(rawValue) }

    var displayName: String {
        switch self {
        case .descending: "Descending"
        case .ascending: "Ascending"
        }
    }

    var systemImage: String {
        switch self {
        case .descending: "arrow.down"
        case .ascending: "arrow.up"
        }
    }
}

enum HuggingFaceCapabilityFilter {
    /// `draft-model` is the emerging convention, but older and vendor-specific
    /// repositories use these aliases. `speculative-decoding` is deliberately
    /// only a search candidate: config metadata must still identify a drafter.
    static let drafterCandidateTags = [
        "draft-model",
        "drafter",
        "speculative-decoding-draft",
        "speculative-decoding",
    ]

    /// Reasoning, tool calling, and drafter are Hub model tags rather than pipeline tasks.
    /// Apply them to the API request so Discover searches the full matching
    /// catalog instead of filtering a small window of unrelated trending models.
    static func hubTags(for capabilities: Set<LocalModelCapability>) -> [String] {
        var tags: [String] = []
        if capabilities.contains(.reasoning) {
            tags.append("reasoning")
        }
        if capabilities.contains(.tools) {
            tags.append("tool-calling")
        }
        if capabilities.contains(.drafter) {
            tags.append("draft-model")
        }
        return tags
    }

    static func hubTagSets(
        for capabilities: Set<LocalModelCapability>
    ) -> [[String]] {
        let canonicalTags = hubTags(for: capabilities)
        guard capabilities.contains(.drafter) else {
            return [canonicalTags]
        }
        let commonTags = canonicalTags.filter { $0 != "draft-model" }
        return drafterCandidateTags.map { commonTags + [$0] }
    }

    /// Select the canonical Hub task for a single Nativ model capability.
    /// Feature-only filters remain Hub tags and do not prevent a task filter
    /// from being sent alongside them.
    static func pipelineTag(for capabilities: Set<LocalModelCapability>) -> String? {
        let taskCapabilities = capabilities.subtracting([.reasoning, .tools, .drafter])
        guard taskCapabilities.count == 1, let capability = taskCapabilities.first else {
            return nil
        }
        switch capability {
        case .text:
            return "text-generation"
        case .vision:
            return "image-text-to-text"
        case .audio:
            return "audio-text-to-text"
        case .video:
            return "video-text-to-text"
        case .imageGeneration:
            return "text-to-image"
        case .imageEditing:
            return "image-to-image"
        case .speechToText:
            return "automatic-speech-recognition"
        case .textToSpeech:
            return "text-to-speech"
        case .embeddings:
            return "feature-extraction"
        case .reranking:
            return "text-ranking"
        case .reasoning, .tools, .drafter:
            return nil
        }
    }

    static func matches(
        _ model: HuggingFaceModel,
        capabilities: Set<LocalModelCapability>
    ) -> Bool {
        capabilities.allSatisfy { model.capabilities.contains($0) }
    }
}

enum HuggingFaceDownloadFilePolicy {
    /// Repositories are selected through the Hub's SafeTensors index. A mixed
    /// repository can still contain optional GGUF artifacts, so exclude those
    /// files from the snapshot instead of hiding the entire repository.
    static let ignoredPatterns = ["*.[gG][gG][uU][fF]"]

    static var pythonListLiteral: String {
        "[" + ignoredPatterns.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    static func shouldIgnore(path: String) -> Bool {
        path.lowercased().hasSuffix(".gguf")
    }
}

struct HuggingFaceModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let downloads: Int
    let likes: Int
    let trendingScore: Double
    let lastModified: String?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]
    let isPrivate: Bool
    let isGated: Bool
    let safetensors: HuggingFaceSafetensors?
    // These values are used by every visible row. Resolve them once while the
    // response is decoded instead of repeating string parsing, provider lookup,
    // and memory estimation during every SwiftUI body pass while scrolling.
    let provider: LocalModelProvider?
    let sizeBytes: Int64?
    let capabilities: Set<LocalModelCapability>
    let memoryEstimate: LocalModelMemoryEstimate?
    let drafterKind: String?

    enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case trendingScore
        case lastModified
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags
        case isPrivate = "private"
        case gated
        case safetensors
        case modelConfiguration = "config"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        trendingScore =
            try container.decodeIfPresent(Double.self, forKey: .trendingScore) ?? 0
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        safetensors = try container.decodeIfPresent(HuggingFaceSafetensors.self, forKey: .safetensors)
        let modelConfiguration = try? container.decode(
            DrafterModelConfiguration.self,
            forKey: .modelConfiguration
        )

        if let value = try? container.decode(Bool.self, forKey: .gated) {
            isGated = value
        } else if let value = try? container.decode(String.self, forKey: .gated) {
            isGated = !value.isEmpty && value != "false"
        } else {
            isGated = false
        }

        provider = LocalModelProviderResolver.resolve(repoID: id, modelType: nil, architectures: [])
        sizeBytes = safetensors?.sizeBytes
        drafterKind =
            MLXDrafterModelResolver.shared.metadata(
                for: modelConfiguration
            )?.kind
        capabilities = Self.resolveCapabilities(
            pipelineTag: pipelineTag,
            libraryName: libraryName,
            tags: tags,
            configIdentifiesDrafter: drafterKind != nil
        )
        memoryEstimate = Self.resolveMemoryEstimate(
            repoID: id,
            safetensors: safetensors,
            sizeBytes: sizeBytes,
            capabilities: capabilities
        )
    }

    // The safetensors parameter summary only covers the diffusion transformer,
    // so for image models it lands well under the real download. Scale it toward
    // the components a modern image pipeline also ships (text encoder + VAE).
    // The download manager validates available capacity again before enqueueing.
    var estimatedDownloadBytes: Int64? {
        guard let sizeBytes else {
            return nil
        }
        let isImageModel = capabilities.contains(.imageGeneration)
            || capabilities.contains(.imageEditing)
        guard isImageModel else {
            return sizeBytes
        }
        let scaled = Double(sizeBytes) * 2.5
        guard scaled <= Double(Int64.max) else {
            return sizeBytes
        }
        return Int64(scaled.rounded(.up))
    }

    private static func resolveMemoryEstimate(
        repoID: String,
        safetensors: HuggingFaceSafetensors?,
        sizeBytes: Int64?,
        capabilities: Set<LocalModelCapability>
    ) -> LocalModelMemoryEstimate? {
        guard let safetensors,
              safetensors.hasOnlyKnownDataTypes,
              let sizeBytes,
              sizeBytes > 0
        else {
            return nil
        }

        let parameterCount = LocalModelDiscovery.parameterCount(from: repoID)
        let quantizationBits = LocalModelDiscovery.quantizationBits(from: repoID)
        var estimatedModelBytes = Double(sizeBytes)

        // Packed integer summaries and explicitly quantized repositories need a
        // second, independent signal before we present a compatibility label.
        if quantizationBits != nil || safetensors.hasPotentiallyPackedWeights {
            guard let parameterCount,
                  let quantizationBits
            else {
                return nil
            }

            let bytesPerParameter = Double(quantizationBits) / 8 + (4 / 64)
            let parameterEstimate = Double(parameterCount) * bytesPerParameter
            let metadataRatio = estimatedModelBytes / parameterEstimate
            guard metadataRatio.isFinite,
                  (0.65...1.75).contains(metadataRatio)
            else {
                return nil
            }
            estimatedModelBytes = max(estimatedModelBytes, parameterEstimate)
        }

        let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        guard totalMemoryBytes > 0,
              estimatedModelBytes.isFinite,
              estimatedModelBytes > 0,
              estimatedModelBytes <= Double(Int64.max)
        else {
            return nil
        }

        let memoryBudgetBytes = UInt64(
            (Double(totalMemoryBytes) * (1 - LocalModelMemoryEstimate.headroomFraction))
                .rounded(.down)
        )
        return LocalModelMemoryEstimate(
            estimatedModelBytes: UInt64(estimatedModelBytes.rounded(.up)),
            memoryBudgetBytes: memoryBudgetBytes,
            totalMemoryBytes: totalMemoryBytes,
            activationReserveBytes: LocalModelMemoryEstimate.activationReserveBytes(for: capabilities)
        )
    }

    private static func resolveCapabilities(
        pipelineTag: String?,
        libraryName: String?,
        tags: [String],
        configIdentifiesDrafter: Bool
    ) -> Set<LocalModelCapability> {
        let pipeline = pipelineTag?.lowercased() ?? ""
        let descriptors = ([pipelineTag, libraryName].compactMap { $0 } + tags)
            .joined(separator: " ")
            .lowercased()
        var result = Set<LocalModelCapability>()

        let textPipelines: Set<String> = [
            "text-generation",
            "image-text-to-text",
            "image-to-text",
            "visual-question-answering",
            "audio-text-to-text",
            "video-text-to-text",
        ]
        if textPipelines.contains(pipeline)
            || descriptors.contains("conversational")
            || descriptors.contains("causal-lm") {
            result.insert(.text)
        }

        let visionPipelines: Set<String> = [
            "image-text-to-text", "image-to-text", "visual-question-answering",
        ]
        if visionPipelines.contains(pipeline)
            || descriptors.contains("vision")
            || descriptors.contains("vlm")
            || descriptors.contains("llava") {
            result.insert(.vision)
        }

        if pipeline.contains("video") || descriptors.contains("video") {
            result.insert(.video)
            result.insert(.vision)
        }

        if pipeline == "text-to-image" {
            result.insert(.imageGeneration)
        }
        if pipeline == "image-to-image" || pipeline == "image-text-to-image" {
            result.insert(.imageEditing)
        }

        if pipeline == "automatic-speech-recognition"
            || descriptors.contains("whisper")
            || descriptors.contains("transcribe")
            || descriptors.contains(" asr") {
            result.insert(.speechToText)
        }

        if pipeline == "text-to-speech" || descriptors.contains(" tts") {
            result.insert(.textToSpeech)
        }

        let embeddingPipelines: Set<String> = [
            "feature-extraction", "image-feature-extraction", "sentence-similarity",
        ]
        if embeddingPipelines.contains(pipeline)
            || descriptors.contains("embedding")
            || descriptors.contains("sentence-transformers") {
            result.insert(.embeddings)
        }

        if pipeline == "text-ranking"
            || descriptors.contains("reranker")
            || descriptors.contains("reranking") {
            result.insert(.reranking)
        }

        if descriptors.contains("reasoning") || descriptors.contains("thinking") {
            result.insert(.reasoning)
        }

        if pipeline.contains("audio")
            || descriptors.contains("speech")
            || result.contains(.speechToText)
            || result.contains(.textToSpeech) {
            result.insert(.audio)
        }

        if descriptors.contains("tool") || descriptors.contains("function-call") {
            result.insert(.tools)
        }

        let normalizedTags = Set(tags.map { $0.lowercased() })
        let drafterTags: Set<String> = [
            "draft-model", "drafter", "speculative-decoding-draft",
        ]
        if !normalizedTags.isDisjoint(with: drafterTags) {
            result.insert(.drafter)
        }
        if configIdentifiesDrafter {
            result.insert(.drafter)
        }
        return result
    }
}

struct HuggingFaceSafetensors: Decodable, Equatable, Sendable {
    let parameters: [String: Int64]

    private static let knownDataTypes: Set<String> = [
        "F64", "I64", "U64", "F32", "I32", "U32", "F16", "BF16", "I16", "U16",
        "F8_E4M3", "F8_E5M2", "I8", "U8", "BOOL", "F6_E2M3", "F6_E3M2", "F4",
        "I4", "U4", "I2", "U2"
    ]

    var hasOnlyKnownDataTypes: Bool {
        !parameters.isEmpty
            && parameters.keys.allSatisfy { Self.knownDataTypes.contains($0.uppercased()) }
    }

    var hasPotentiallyPackedWeights: Bool {
        let totalCount = parameters.values.reduce(Int64(0)) { partialResult, count in
            partialResult.addingReportingOverflow(count).overflow
                ? Int64.max
                : partialResult + count
        }
        guard totalCount > 0 else {
            return false
        }
        let packedCount = parameters.reduce(Int64(0)) { partialResult, entry in
            guard ["I32", "U32"].contains(entry.key.uppercased()) else {
                return partialResult
            }
            return partialResult.addingReportingOverflow(entry.value).overflow
                ? Int64.max
                : partialResult + entry.value
        }
        return Double(packedCount) / Double(totalCount) >= 0.10
    }

    var sizeBytes: Int64? {
        guard !parameters.isEmpty else { return nil }

        let byteCount = parameters.reduce(0.0) { result, entry in
            result + (Double(entry.value) * bitsPerParameter(for: entry.key) / 8)
        }
        guard byteCount.isFinite, byteCount > 0, byteCount <= Double(Int64.max) else {
            return nil
        }
        return Int64(byteCount.rounded(.up))
    }

    private func bitsPerParameter(for dataType: String) -> Double {
        switch dataType.uppercased() {
        case "F64", "I64", "U64":
            64
        case "F32", "I32", "U32":
            32
        case "F16", "BF16", "I16", "U16":
            16
        case "F8_E4M3", "F8_E5M2", "I8", "U8", "BOOL":
            8
        case "F6_E2M3", "F6_E3M2":
            6
        case "F4", "I4", "U4":
            4
        case "I2", "U2":
            2
        default:
            16
        }
    }
}

enum HuggingFaceHubError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String)
    case pythonUnavailable
    case downloadStalled
    case anotherDownloadInProgress(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Hugging Face Hub returned an invalid response."
        case .requestFailed(let status, let message):
            message.isEmpty ? "Hugging Face Hub request failed (HTTP \(status))." : message
        case .pythonUnavailable:
            "The bundled model downloader is unavailable."
        case .downloadStalled:
            "The model download stopped responding after multiple automatic retries. Check your connection and try again."
        case .anotherDownloadInProgress(let modelID):
            "Wait for \(modelID) to finish downloading before starting another model download."
        }
    }
}

enum HuggingFaceDownloadFailure: LocalizedError, Equatable {
    case gatedRepository
    case message(String)

    init(processOutput: String) {
        let normalizedOutput = processOutput.lowercased()
        if normalizedOutput.contains("gatedrepoerror")
            || normalizedOutput.contains("cannot access gated repo")
            || normalizedOutput.contains("is restricted and you are not in the authorized list") {
            self = .gatedRepository
            return
        }

        let usefulMessage = processOutput
            .split(whereSeparator: { $0.isNewline || $0 == "\r" })
            .suffix(4)
            .joined(separator: "\n")
        self = .message(
            usefulMessage.isEmpty ? "The model download failed. Try again." : usefulMessage
        )
    }

    var errorDescription: String? {
        switch self {
        case .gatedRepository:
            "This gated model requires access approval from its publisher."
        case .message(let message):
            message
        }
    }
}

private struct HuggingFaceHubClient: Sendable {
    func search(
        query: String,
        sort: HuggingFaceModelSort,
        capabilities: Set<LocalModelCapability>,
        token: String?
    ) async throws -> HuggingFaceModelPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = try HuggingFaceCapabilityFilter.hubTagSets(for: capabilities).map {
            hubTags in
            var components = URLComponents()
            components.scheme = "https"
            components.host = "huggingface.co"
            components.path = "/api/models"

            let hubFilters = ["safetensors"] + hubTags
            var queryItems = [
                URLQueryItem(name: "filter", value: hubFilters.joined(separator: ",")),
                URLQueryItem(name: "sort", value: sort.apiSortValue),
                // The Hub API currently rejects ascending requests for every sort.
                // Ascending results are prepared locally by the library below.
                URLQueryItem(
                    name: "direction",
                    value: HuggingFaceSortDirection.descending.apiValue
                ),
                URLQueryItem(name: "limit", value: "50"),
            ]
            if let pipelineTag = HuggingFaceCapabilityFilter.pipelineTag(for: capabilities) {
                queryItems.append(URLQueryItem(name: "pipeline_tag", value: pipelineTag))
            }
            queryItems.append(
                contentsOf: Self.expandedFields.map {
                    URLQueryItem(name: "expand[]", value: $0)
                })
            if !trimmedQuery.isEmpty {
                queryItems.append(URLQueryItem(name: "search", value: trimmedQuery))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw HuggingFaceHubError.invalidResponse
            }
            return url
        }
        return try await pages(at: urls, token: token)
    }

    func modelData(id: String, token: String?) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(id)"
        components.queryItems = Self.expandedFields.map {
            URLQueryItem(name: "expand[]", value: $0)
        }

        guard let url = components.url else {
            throw HuggingFaceHubError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MLXPlatform/1.0", forHTTPHeaderField: "User-Agent")
        HuggingFaceAuthentication.authorize(&request, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HuggingFaceHubError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(HubErrorPayload.self, from: data))?.error ?? ""
            throw HuggingFaceHubError.requestFailed(httpResponse.statusCode, message)
        }
        return data
    }

    func page(at url: URL, token: String?) async throws -> HuggingFaceModelPage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MLXPlatform/1.0", forHTTPHeaderField: "User-Agent")
        HuggingFaceAuthentication.authorize(&request, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HuggingFaceHubError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(HubErrorPayload.self, from: data))?.error ?? ""
            throw HuggingFaceHubError.requestFailed(httpResponse.statusCode, message)
        }
        let models = try JSONDecoder()
            .decode([HuggingFaceModel].self, from: data)
            .filter {
                !$0.id.lowercased().hasPrefix("lmstudio-community/")
            }
        return HuggingFaceModelPage(
            models: models,
            nextPageURLs: [
                nextPageURL(from: httpResponse.value(forHTTPHeaderField: "Link"))
            ].compactMap { $0 }
        )
    }

    func pages(at urls: [URL], token: String?) async throws -> HuggingFaceModelPage {
        let indexedPages = try await withThrowingTaskGroup(
            of: (Int, HuggingFaceModelPage).self,
            returning: [(Int, HuggingFaceModelPage)].self
        ) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    (index, try await page(at: url, token: token))
                }
            }

            var pages: [(Int, HuggingFaceModelPage)] = []
            for try await page in group {
                pages.append(page)
            }
            return pages.sorted { $0.0 < $1.0 }
        }

        var seenIDs = Set<String>()
        let models = indexedPages.flatMap(\.1.models).filter {
            seenIDs.insert($0.id).inserted
        }
        return HuggingFaceModelPage(
            models: models,
            nextPageURLs: indexedPages.flatMap(\.1.nextPageURLs)
        )
    }

    private func nextPageURL(from linkHeader: String?) -> URL? {
        guard let nextLink = linkHeader?
            .split(separator: ",")
            .first(where: { $0.contains("rel=\"next\"") }),
              let start = nextLink.firstIndex(of: "<"),
              let end = nextLink[start...].firstIndex(of: ">")
        else {
            return nil
        }
        return URL(string: String(nextLink[nextLink.index(after: start)..<end]))
    }

    private static let expandedFields = [
        "downloads", "likes", "trendingScore", "lastModified", "pipeline_tag",
        "library_name", "tags", "private", "gated", "safetensors", "config",
    ]
}

private struct HuggingFaceModelPage: Sendable {
    let models: [HuggingFaceModel]
    let nextPageURLs: [URL]
}

struct HuggingFaceCuratedModelLoader: Sendable {
    typealias FetchModelData = @Sendable (String) async -> Data?

    private let maximumConcurrentRequests: Int
    private let fetchModelData: FetchModelData

    init(
        maximumConcurrentRequests: Int = 4,
        fetchModelData: @escaping FetchModelData
    ) {
        precondition(maximumConcurrentRequests > 0)
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.fetchModelData = fetchModelData
    }

    func load(ids: [String]) async -> [HuggingFaceModel] {
        let payloads = await fetchPayloads(ids: ids)
        guard !Task.isCancelled else {
            return []
        }

        // Model decoding derives memory metadata and compiles model-name regexes.
        // Keep it sequential while allowing the network requests to overlap.
        let decoder = JSONDecoder()
        return ids.compactMap { id in
            guard let data = payloads[id] else {
                return nil
            }
            return try? decoder.decode(HuggingFaceModel.self, from: data)
        }
    }

    private func fetchPayloads(ids: [String]) async -> [String: Data] {
        let fetchModelData = self.fetchModelData
        return await withTaskGroup(
            of: (String, Data?).self,
            returning: [String: Data].self
        ) { group in
            var iterator = ids.makeIterator()
            var payloads: [String: Data] = [:]
            let initialRequestCount = min(maximumConcurrentRequests, ids.count)

            for _ in 0..<initialRequestCount {
                guard let id = iterator.next() else { break }
                group.addTask {
                    (id, await fetchModelData(id))
                }
            }

            while let (id, data) = await group.next() {
                if let data {
                    payloads[id] = data
                }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let nextID = iterator.next() {
                    group.addTask {
                        (nextID, await fetchModelData(nextID))
                    }
                }
            }
            return payloads
        }
    }
}

enum HuggingFaceModelCatalog {
    static func popularModels(
        with capability: LocalModelCapability,
        token: String?
    ) async throws -> [HuggingFaceModel] {
        let hubCapability: LocalModelCapability = capability == .imageEditing
            ? .imageGeneration
            : capability
        return try await HuggingFaceHubClient().search(
            query: "mlx",
            sort: .downloads,
            capabilities: [hubCapability],
            token: token
        ).models
    }
}

private struct HubErrorPayload: Decodable {
    let error: String
}

@MainActor
final class HuggingFaceModelLibrary: ObservableObject {
    @Published private(set) var models: [HuggingFaceModel] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var pageNumber = 1

    private let client = HuggingFaceHubClient()
    private var searchTask: Task<Void, Never>?
    private var buffer: [HuggingFaceModel] = []
    private var activeSort: HuggingFaceModelSort = .downloads
    private var activeDirection: HuggingFaceSortDirection = .descending
    private var visibilityPredicate: (HuggingFaceModel) -> Bool = { _ in true }
    private var nextPageURLs: [URL] = []
    private let pageSize = 24
    private let maximumPageCount = 5
    private let maximumFillFetches = 8

    deinit {
        searchTask?.cancel()
    }

    func search(
        query: String,
        sort: HuggingFaceModelSort,
        direction: HuggingFaceSortDirection,
        capabilities: Set<LocalModelCapability>,
        predicate: @escaping (HuggingFaceModel) -> Bool,
        token: String?
    ) {
        searchTask?.cancel()
        isSearching = true
        error = nil
        models = []
        buffer = []
        nextPageURLs = []
        pageNumber = 1
        activeSort = sort
        activeDirection = direction
        visibilityPredicate = predicate

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await client.search(
                    query: query,
                    sort: sort,
                    capabilities: capabilities,
                    token: token
                )
                try Task.checkCancellation()
                self.mergeIntoBuffer(page.models)
                self.nextPageURLs = page.nextPageURLs
                let needsStableLocalOrdering = sort.sortsBySize || direction == .ascending
                let targetCount = needsStableLocalOrdering
                    ? self.maximumPageCount * self.pageSize : self.pageSize
                try await self.fillBuffer(upTo: targetCount, token: token)
                if needsStableLocalOrdering {
                    // Local ordering spans Nativ's complete five-page window.
                    // Stop here so later pagination cannot reshuffle earlier pages.
                    self.nextPageURLs = []
                }
                try Task.checkCancellation()
                self.models = self.slice(forPage: 1)
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.buffer = []
                self.models = []
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    func loadCurated(ids: [String], token: String?) {
        searchTask?.cancel()
        isSearching = true
        error = nil
        models = []
        buffer = []
        nextPageURLs = []
        pageNumber = 1
        activeSort = .downloads
        activeDirection = .descending
        visibilityPredicate = { _ in true }

        searchTask = Task { [weak self] in
            guard let self else { return }
            let client = self.client
            let loader = HuggingFaceCuratedModelLoader { id in
                try? await client.modelData(id: id, token: token)
            }
            let ordered = await loader.load(ids: ids)
            guard !Task.isCancelled else { return }
            self.buffer = ordered
            self.models = ordered
            self.error = ordered.isEmpty
                ? HuggingFaceHubError.invalidResponse.errorDescription
                : nil
            self.isSearching = false
        }
    }

    var canGoToPreviousPage: Bool {
        pageNumber > 1 && !isSearching
    }

    var canGoToNextPage: Bool {
        guard !isSearching, pageNumber < maximumPageCount else { return false }
        return orderedVisible.count > pageNumber * pageSize || !nextPageURLs.isEmpty
    }

    func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        pageNumber -= 1
        models = slice(forPage: pageNumber)
        error = nil
    }

    func goToNextPage(token: String?) {
        guard canGoToNextPage else { return }
        let target = pageNumber + 1

        if orderedVisible.count >= target * pageSize || nextPageURLs.isEmpty {
            pageNumber = target
            models = slice(forPage: target)
            error = nil
            return
        }

        searchTask?.cancel()
        isSearching = true
        error = nil

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.fillBuffer(upTo: target * self.pageSize, token: token)
                try Task.checkCancellation()
                let nextModels = self.slice(forPage: target)
                if !nextModels.isEmpty {
                    self.pageNumber = target
                    self.models = nextModels
                }
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    private func fillBuffer(upTo count: Int, token: String?) async throws {
        var fetchRounds = 0
        while orderedVisible.count < count,
            !nextPageURLs.isEmpty,
            fetchRounds < maximumFillFetches
        {
            let nextPage = try await client.pages(at: nextPageURLs, token: token)
            try Task.checkCancellation()
            mergeIntoBuffer(nextPage.models)
            nextPageURLs = nextPage.nextPageURLs
            fetchRounds += 1
        }
    }

    private func mergeIntoBuffer(_ models: [HuggingFaceModel]) {
        var knownIDs = Set(buffer.map(\.id))
        buffer.append(contentsOf: models.filter { knownIDs.insert($0.id).inserted })
    }

    private func slice(forPage number: Int) -> [HuggingFaceModel] {
        let ordered = orderedVisible
        let start = (number - 1) * pageSize
        guard start < ordered.count else { return [] }
        return Array(ordered[start..<min(start + pageSize, ordered.count)])
    }

    /// Buffered results in display order. Drafter discovery merges several Hub
    /// tag searches, so every sort is applied locally after de-duplication.
    private var orderedBuffer: [HuggingFaceModel] {
        buffer.sorted { lhs, rhs in
            let isAscending = activeDirection == .ascending
            switch activeSort {
            case .downloads:
                if lhs.downloads != rhs.downloads {
                    return isAscending
                        ? lhs.downloads < rhs.downloads : lhs.downloads > rhs.downloads
                }
            case .trending:
                if lhs.trendingScore != rhs.trendingScore {
                    return isAscending
                        ? lhs.trendingScore < rhs.trendingScore
                        : lhs.trendingScore > rhs.trendingScore
                }
            case .likes:
                if lhs.likes != rhs.likes {
                    return isAscending ? lhs.likes < rhs.likes : lhs.likes > rhs.likes
                }
            case .recentlyUpdated:
                if lhs.lastModified != rhs.lastModified {
                    switch (lhs.lastModified, rhs.lastModified) {
                    case (let lhsDate?, let rhsDate?):
                        return isAscending ? lhsDate < rhsDate : lhsDate > rhsDate
                    case (nil, _):
                        return false
                    case (_, nil):
                        return true
                    }
                }
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes {
                    switch (lhs.sizeBytes, rhs.sizeBytes) {
                    case (let lhsSize?, let rhsSize?):
                        return isAscending ? lhsSize < rhsSize : lhsSize > rhsSize
                    case (nil, _):
                        return false
                    case (_, nil):
                        return true
                    }
                }
            }
            let comparison = lhs.id.localizedCaseInsensitiveCompare(rhs.id)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private var orderedVisible: [HuggingFaceModel] {
        orderedBuffer.filter(visibilityPredicate)
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}

struct ModelDownloadProgress: Equatable, Sendable {
    private(set) var completedBytes: Int64
    private(set) var totalBytes: Int64?

    init(totalBytes: Int64?) {
        self.completedBytes = 0
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    init?(completedBytes: Int64, totalBytes: Int64) {
        guard totalBytes > 0 else { return nil }
        self.completedBytes = min(max(completedBytes, 0), totalBytes)
        self.totalBytes = totalBytes
    }

    var fractionCompleted: Double {
        guard let totalBytes else { return 0 }
        return Double(completedBytes) / Double(totalBytes)
    }

    var remainingBytes: Int64? {
        totalBytes.map { max($0 - completedBytes, 0) }
    }

    mutating func merge(_ update: Self) -> Bool {
        guard update.totalBytes != totalBytes || update.completedBytes > completedBytes else {
            return false
        }

        if update.totalBytes == totalBytes {
            completedBytes = max(completedBytes, update.completedBytes)
        } else {
            self = update
        }
        return true
    }
}

struct ModelDownloadProgressLimiter {
    static let publishInterval: Duration = .milliseconds(100)

    private var lastPublishedAt: ContinuousClock.Instant?
    private(set) var pending: ModelDownloadProgress?

    mutating func submit(
        _ update: ModelDownloadProgress,
        current: ModelDownloadProgress,
        at now: ContinuousClock.Instant
    ) -> ModelDownloadProgress? {
        var merged = pending ?? current
        guard merged.merge(update) else { return nil }

        let isComplete = merged.totalBytes.map { merged.completedBytes >= $0 } == true
        let canPublish = lastPublishedAt.map {
            now >= $0.advanced(by: Self.publishInterval)
        } ?? true
        guard isComplete || canPublish else {
            pending = merged
            return nil
        }

        pending = nil
        lastPublishedAt = now
        return merged
    }

    func pendingPublishDelay(at now: ContinuousClock.Instant) -> Duration? {
        guard pending != nil, let lastPublishedAt else { return nil }
        let deadline = lastPublishedAt.advanced(by: Self.publishInterval)
        return now < deadline ? now.duration(to: deadline) : .zero
    }

    mutating func flush(at now: ContinuousClock.Instant) -> ModelDownloadProgress? {
        guard let pending else { return nil }
        self.pending = nil
        lastPublishedAt = now
        return pending
    }
}

@MainActor
final class HuggingFaceDownloadManager: ObservableObject {
    static let shared = HuggingFaceDownloadManager()

    enum DownloadState: Equatable {
        case downloading
        case paused
    }

    enum DownloadPhase: Equatable {
        case preparing
        case downloading
        case finalizing
        case retrying
    }

    struct RowSnapshot: Equatable {
        let isDownloading: Bool
        let progress: Double
        let isPaused: Bool
        let error: HuggingFaceDownloadFailure?
    }

    struct ActiveDownload: Identifiable, Equatable {
        let modelID: String
        var metrics: ModelDownloadProgress
        var bytesPerSecond: Double?
        var state: DownloadState
        var phase: DownloadPhase

        var id: String { modelID }
        var progress: Double { metrics.fractionCompleted }
    }

    private final class DownloadContext {
        let modelID: String
        let cachePath: String
        let volumeIdentifier: String?
        let token: String?
        var onCompletion: (() -> Void)?
        var operation: HuggingFaceDownloadOperation?
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        init(
            modelID: String,
            cachePath: String,
            volumeIdentifier: String?,
            token: String?,
            onCompletion: (() -> Void)?
        ) {
            self.modelID = modelID
            self.cachePath = cachePath
            self.volumeIdentifier = volumeIdentifier
            self.token = token
            self.onCompletion = onCompletion
        }
    }

    @Published private(set) var downloads: [ActiveDownload] = []
    @Published private(set) var errorByModelID: [String: HuggingFaceDownloadFailure] = [:]
    /// Emits the affected model ID for progress/state changes. `nil` denotes
    /// a structural change that can affect capacity for every download row.
    let rowUpdates = PassthroughSubject<String?, Never>()

    private var contexts: [String: DownloadContext] = [:]
    private let progressClock = ContinuousClock()
    private var progressLimiters: [String: ModelDownloadProgressLimiter] = [:]
    private var progressFlushTasks: [String: Task<Void, Never>] = [:]
    private var freeDiskCache: [String: (timestamp: Date, bytes: Int64?)] = [:]

    isolated deinit {
        progressFlushTasks.values.forEach { $0.cancel() }
        contexts.values.forEach {
            $0.operation?.cancel()
            $0.task?.cancel()
        }
    }

    var activeCount: Int { downloads.count }

    var reservedBytes: Int64 {
        downloads.reduce(Int64(0)) { total, download in
            total + (download.metrics.remainingBytes ?? 0)
        }
    }

    func isDownloading(_ modelID: String) -> Bool {
        contexts[modelID] != nil
    }

    func progress(for modelID: String) -> Double {
        downloads.first { $0.modelID == modelID }?.progress ?? 0
    }

    func isPaused(for modelID: String) -> Bool {
        downloads.first { $0.modelID == modelID }?.state == .paused
    }

    func rowSnapshot(for modelID: String) -> RowSnapshot {
        let download = downloads.first { $0.modelID == modelID }
        return RowSnapshot(
            isDownloading: download != nil,
            progress: download?.progress ?? 0,
            isPaused: download?.state == .paused,
            error: errorByModelID[modelID]
        )
    }

    func state(for modelID: String) -> DownloadState? {
        downloads.first { $0.modelID == modelID }?.state
    }

    func reportError(_ message: String, for modelID: String) {
        errorByModelID[modelID] = .message(message)
    }

    func capacityBlocker(sizeBytes: Int64?, cachePath: String) -> String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        let path = LocalModelDiscovery.expandedPath(cachePath)
        guard let freeBytes = cachedFreeDiskBytes(atPath: path) else { return nil }
        let availableBytes = max(freeBytes - reservedBytes, 0)
        guard sizeBytes > availableBytes else { return nil }
        let needed = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        return "Needs \(needed) but only \(available) is free after reserving space for in-progress downloads."
    }

    func download(
        repoID: String,
        sizeBytes: Int64?,
        cachePath: String,
        volumeIdentifier: String?,
        token: String?,
        onCompletion: @escaping () -> Void
    ) {
        guard contexts[repoID] == nil else { return }
        do {
            _ = try ExternalModelCacheReference.validateForUse(
                path: cachePath,
                expectedVolumeIdentifier: volumeIdentifier
            )
            if let blocker = capacityBlocker(sizeBytes: sizeBytes, cachePath: cachePath) {
                throw HuggingFaceDownloadFailure.message(blocker)
            }
            try enqueue(
                repoID: repoID,
                sizeBytes: sizeBytes,
                cachePath: cachePath,
                volumeIdentifier: volumeIdentifier,
                token: token,
                onCompletion: onCompletion
            )
        } catch {
            errorByModelID[repoID] = downloadFailure(for: error)
            rowUpdates.send(repoID)
        }
    }

    func downloadIfNeeded(
        repoID: String,
        sizeBytes: Int64?,
        cachePath: String,
        volumeIdentifier: String?,
        token: String?
    ) async throws {
        let expandedCachePath = LocalModelDiscovery.expandedPath(cachePath)
        if let context = contexts[repoID] {
            guard context.cachePath == expandedCachePath,
                  context.volumeIdentifier == volumeIdentifier else {
                throw HuggingFaceHubError.anotherDownloadInProgress(repoID)
            }
        } else {
            do {
                try enqueue(
                    repoID: repoID,
                    sizeBytes: sizeBytes,
                    cachePath: expandedCachePath,
                    volumeIdentifier: volumeIdentifier,
                    token: token,
                    onCompletion: nil
                )
            } catch {
                errorByModelID[repoID] = downloadFailure(for: error)
                rowUpdates.send(repoID)
                throw error
            }
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, let context = contexts[repoID] else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                context.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, modelID: repoID)
            }
        }
    }

    func pauseDownload(_ modelID: String) {
        guard let context = contexts[modelID], state(for: modelID) == .downloading else { return }
        context.operation?.pause()
        setState(modelID, .paused)
    }

    func resumeDownload(_ modelID: String) {
        guard let context = contexts[modelID], state(for: modelID) == .paused else { return }
        do {
            _ = try ExternalModelCacheReference.validateForUse(
                path: context.cachePath,
                expectedVolumeIdentifier: context.volumeIdentifier
            )
        } catch {
            context.task?.cancel()
            context.operation?.cancel()
            finishDownload(repoID: modelID, error: downloadFailure(for: error))
            return
        }
        context.operation?.resume()
        setState(modelID, .downloading)
    }

    func removeDownload(_ modelID: String) {
        guard let context = contexts[modelID] else { return }
        let task = context.task
        let cachePath = context.cachePath
        let volumeIdentifier = context.volumeIdentifier
        task?.cancel()
        let waiters = Array(context.waiters.values)
        removeContext(modelID)
        waiters.forEach { $0.resume(throwing: CancellationError()) }

        Task {
            await task?.value
            await Task.detached(priority: .utility) {
                HuggingFaceSnapshotDownloader.removeDownload(
                    repoID: modelID,
                    cachePath: cachePath,
                    volumeIdentifier: volumeIdentifier
                )
            }.value
        }
    }

    /// Stops downloader subprocesses before the app exits while preserving the
    /// Hugging Face cache, including resumable `.incomplete` files.
    func shutdownForTermination(timeout: Duration = .seconds(2)) async {
        let activeContexts = Array(contexts.values)
        let waiters = activeContexts.flatMap { $0.waiters.values }
        let operations = activeContexts.compactMap(\.operation)

        activeContexts.forEach { context in
            context.task?.cancel()
            context.operation?.cancel()
        }

        contexts.removeAll()
        progressFlushTasks.values.forEach { $0.cancel() }
        progressFlushTasks.removeAll()
        progressLimiters.removeAll()
        downloads.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }

        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask {
                    await operation.waitForExit(timeout: timeout)
                }
            }
        }
    }

    private func enqueue(
        repoID: String,
        sizeBytes: Int64?,
        cachePath: String,
        volumeIdentifier: String?,
        token: String?,
        onCompletion: (() -> Void)?
    ) throws {
        let cacheURL = try ExternalModelCacheReference.validateForUse(
            path: cachePath,
            expectedVolumeIdentifier: volumeIdentifier
        )
        let context = DownloadContext(
            modelID: repoID,
            cachePath: cacheURL.path,
            volumeIdentifier: volumeIdentifier,
            token: token,
            onCompletion: onCompletion
        )
        contexts[repoID] = context
        errorByModelID[repoID] = nil
        downloads.append(
            ActiveDownload(
                modelID: repoID,
                metrics: ModelDownloadProgress(totalBytes: sizeBytes),
                bytesPerSecond: nil,
                state: .downloading,
                phase: .preparing
            )
        )
        do {
            try startDownload(context)
            rowUpdates.send(nil)
        } catch {
            removeContext(repoID)
            throw error
        }
    }

    private func startDownload(_ context: DownloadContext) throws {
        let repoID = context.modelID
        let normalizedToken = HuggingFaceAuthentication.normalizedToken(context.token)
        let operation = try HuggingFaceDownloadOperation(
            repoID: repoID,
            cachePath: context.cachePath,
            token: normalizedToken,
            progress: { progress in
                Task { @MainActor [weak self] in
                    self?.updateProgress(repoID, progress)
                }
            },
            transferSpeed: { bytesPerSecond in
                Task { @MainActor [weak self] in
                    self?.updateTransferSpeed(repoID, bytesPerSecond)
                }
            },
            phase: { phase in
                Task { @MainActor [weak self] in
                    self?.updatePhase(repoID, phase)
                }
            }
        )

        context.operation = operation
        context.task = Task { [weak self] in
            do {
                try await HuggingFaceSnapshotDownloader.download(operation: operation)
                guard !Task.isCancelled else { return }
                self?.finishDownload(repoID: repoID, error: nil)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishDownload(repoID: repoID, error: error)
            }
        }
    }

    private func finishDownload(repoID: String, error: Error?) {
        guard let context = contexts[repoID] else { return }
        let completion = context.onCompletion
        let waiters = Array(context.waiters.values)
        if let error {
            errorByModelID[repoID] = downloadFailure(for: error)
        }
        removeContext(repoID)

        if let error {
            waiters.forEach { $0.resume(throwing: error) }
        } else {
            NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
            completion?()
            waiters.forEach { $0.resume() }
        }
    }

    private func updateProgress(_ modelID: String, _ progress: ModelDownloadProgress) {
        guard contexts[modelID] != nil,
              let index = downloads.firstIndex(where: { $0.modelID == modelID })
        else {
            return
        }
        let now = progressClock.now
        var limiter = progressLimiters[modelID] ?? ModelDownloadProgressLimiter()
        let metrics = limiter.submit(progress, current: downloads[index].metrics, at: now)
        let delay = limiter.pendingPublishDelay(at: now)
        progressLimiters[modelID] = limiter

        if let metrics {
            progressFlushTasks.removeValue(forKey: modelID)?.cancel()
            publishProgress(metrics, for: modelID)
        } else if let delay, progressFlushTasks[modelID] == nil {
            progressFlushTasks[modelID] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.flushProgress(for: modelID)
            }
        }
    }

    private func flushProgress(for modelID: String) {
        progressFlushTasks[modelID] = nil
        guard contexts[modelID] != nil,
              var limiter = progressLimiters[modelID],
              let metrics = limiter.flush(at: progressClock.now)
        else {
            return
        }
        progressLimiters[modelID] = limiter
        publishProgress(metrics, for: modelID)
    }

    private func publishProgress(_ metrics: ModelDownloadProgress, for modelID: String) {
        guard let index = downloads.firstIndex(where: { $0.modelID == modelID }),
              downloads[index].metrics != metrics
        else {
            return
        }
        downloads[index].metrics = metrics
        rowUpdates.send(modelID)
    }

    private func updatePhase(_ modelID: String, _ phase: DownloadPhase) {
        guard let index = downloads.firstIndex(where: { $0.modelID == modelID }),
              downloads[index].phase != phase
        else {
            return
        }
        downloads[index].phase = phase
        if phase != .downloading {
            downloads[index].bytesPerSecond = nil
        }
        rowUpdates.send(modelID)
    }

    private func updateTransferSpeed(_ modelID: String, _ bytesPerSecond: Double?) {
        guard let index = downloads.firstIndex(where: { $0.modelID == modelID }),
              downloads[index].state == .downloading,
              downloads[index].phase == .downloading
        else {
            return
        }
        let normalizedSpeed = bytesPerSecond.flatMap { speed in
            speed.isFinite && speed >= 0 ? speed : nil
        }
        guard downloads[index].bytesPerSecond != normalizedSpeed else { return }
        downloads[index].bytesPerSecond = normalizedSpeed
    }

    private func setState(_ modelID: String, _ state: DownloadState) {
        guard let index = downloads.firstIndex(where: { $0.modelID == modelID }) else { return }
        downloads[index].state = state
        downloads[index].bytesPerSecond = nil
        rowUpdates.send(modelID)
    }

    private func removeContext(_ modelID: String) {
        contexts.removeValue(forKey: modelID)
        progressFlushTasks.removeValue(forKey: modelID)?.cancel()
        progressLimiters.removeValue(forKey: modelID)
        downloads.removeAll { $0.modelID == modelID }
        rowUpdates.send(nil)
    }

    private func downloadFailure(for error: Error) -> HuggingFaceDownloadFailure {
        if let failure = error as? HuggingFaceDownloadFailure {
            return failure
        }
        return .message(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }

    private func cancelWaiter(_ waiterID: UUID, modelID: String) {
        contexts[modelID]?.waiters.removeValue(forKey: waiterID)?
            .resume(throwing: CancellationError())
    }

    private static func freeDiskBytes(atPath path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeBytes = attributes[.systemFreeSize] as? Int64
        else {
            return nil
        }
        return freeBytes
    }

    private func cachedFreeDiskBytes(atPath path: String) -> Int64? {
        let now = Date()
        if let cached = freeDiskCache[path], now.timeIntervalSince(cached.timestamp) < 1 {
            return cached.bytes
        }
        let bytes = Self.freeDiskBytes(atPath: path)
        freeDiskCache[path] = (timestamp: now, bytes: bytes)
        return bytes
    }
}

private enum HuggingFaceSnapshotDownloader {
    static func download(operation: HuggingFaceDownloadOperation) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try operation.run()
            }.value
        } onCancel: {
            operation.cancel()
        }
    }

    static func removeDownload(
        repoID: String,
        cachePath: String,
        volumeIdentifier: String?
    ) {
        guard let cacheURL = try? ExternalModelCacheReference.validateForUse(
            path: cachePath,
            expectedVolumeIdentifier: volumeIdentifier
        ) else {
            return
        }
        let repositoryDirectory = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: cacheURL.appendingPathComponent(repositoryDirectory, isDirectory: true))
        try? fileManager.removeItem(
            at: cacheURL
                .appendingPathComponent(".locks", isDirectory: true)
                .appendingPathComponent(repositoryDirectory, isDirectory: true)
        )
    }
}

struct HuggingFaceDownloadProgressState: Equatable {
    private static let speedSampleInterval: TimeInterval = 0.4
    private static let speedStaleInterval: TimeInterval = 2

    private(set) var progress: ModelDownloadProgress?
    private(set) var lastActivity: Date
    private(set) var bytesPerSecond: Double?
    private var reconstructedBytes: Int64 = 0
    private var transferredBytes: Int64 = 0
    private var speedSampleBytes: Int64 = 0
    private var speedSampleTime: Date
    private var lastTransferTime: Date?
    private var checkpointReconstructedBytes: Int64 = 0
    private var checkpointTransferredBytes: Int64 = 0
    private var checkpointDisplayedBytes: Int64 = 0
    private var logicalBytesPerTransferByte = 1.0

    init(now: Date = .now) {
        self.lastActivity = now
        self.bytesPerSecond = nil
        self.speedSampleTime = now
    }

    mutating func beginAttempt(at now: Date = .now) {
        lastActivity = now
        bytesPerSecond = nil
        transferredBytes = 0
        speedSampleBytes = 0
        speedSampleTime = now
        lastTransferTime = nil
        checkpointReconstructedBytes = reconstructedBytes
        checkpointTransferredBytes = 0
        checkpointDisplayedBytes = progress?.completedBytes ?? 0
    }

    mutating func resume(at now: Date = .now) {
        lastActivity = now
        bytesPerSecond = nil
        speedSampleBytes = transferredBytes
        speedSampleTime = now
        lastTransferTime = nil
    }

    mutating func recordProgress(
        _ update: ModelDownloadProgress,
        at now: Date = .now
    ) -> ModelDownloadProgress? {
        let hasNewBytes = update.completedBytes > reconstructedBytes
        let hasNewTotal = update.totalBytes != progress?.totalBytes
        guard hasNewBytes || hasNewTotal else { return nil }

        let nextReconstructedBytes = max(reconstructedBytes, update.completedBytes)
        let logicalDelta = nextReconstructedBytes - checkpointReconstructedBytes
        let transferDelta = transferredBytes - checkpointTransferredBytes
        if logicalDelta > 0, transferDelta > 0 {
            // Xet reconstructs in buffered bursts. Re-anchor to each exact
            // update, then advance smoothly using network bytes between them.
            let observedRatio = Double(logicalDelta) / Double(transferDelta)
            let boundedRatio = min(max(observedRatio, 0.25), 4)
            logicalBytesPerTransferByte = (logicalBytesPerTransferByte + boundedRatio) / 2
        }

        reconstructedBytes = nextReconstructedBytes
        let displayedBytes = max(progress?.completedBytes ?? 0, reconstructedBytes)
        guard let totalBytes = update.totalBytes,
              let nextProgress = ModelDownloadProgress(
                  completedBytes: displayedBytes,
                  totalBytes: totalBytes
              )
        else {
            return nil
        }

        checkpointReconstructedBytes = reconstructedBytes
        checkpointTransferredBytes = transferredBytes
        checkpointDisplayedBytes = nextProgress.completedBytes
        lastActivity = now
        guard nextProgress != progress else { return nil }
        progress = nextProgress
        return nextProgress
    }

    mutating func recordTransferredBytes(
        _ bytes: Int64,
        at now: Date = .now
    ) -> ModelDownloadProgress? {
        let bytes = max(bytes, 0)
        guard bytes > transferredBytes else { return nil }

        transferredBytes = bytes
        lastActivity = now
        lastTransferTime = now

        let elapsed = now.timeIntervalSince(speedSampleTime)
        if elapsed >= Self.speedSampleInterval {
            let currentSpeed = Double(bytes - speedSampleBytes) / elapsed
            bytesPerSecond = bytesPerSecond.map {
                ($0 * 0.65) + (currentSpeed * 0.35)
            } ?? currentSpeed
            speedSampleBytes = bytes
            speedSampleTime = now
        }

        guard let totalBytes = progress?.totalBytes else { return nil }
        let transferDelta = bytes - checkpointTransferredBytes
        let estimatedBytes = checkpointDisplayedBytes
            + Int64(Double(transferDelta) * logicalBytesPerTransferByte)
        // Transfer bytes are only an estimate of reconstructed bytes. Cap the
        // estimate at the first finishing byte so it cannot show 100%, but can
        // still switch the UI and stall watchdog into their finishing state.
        let activeLimit = min(
            Int64(
                (Double(totalBytes) * ModelDownloadProgressPresentation.finishingThreshold)
                    .rounded(.up)
            ),
            totalBytes
        )
        guard let estimate = ModelDownloadProgress(
            completedBytes: min(estimatedBytes, activeLimit),
            totalBytes: totalBytes
        ), var progress, progress.merge(estimate) else {
            return nil
        }
        self.progress = progress
        return progress
    }

    func transferSpeed(at now: Date = .now) -> Double? {
        guard let lastTransferTime,
              now.timeIntervalSince(lastTransferTime) < Self.speedStaleInterval
        else {
            return nil
        }
        return bytesPerSecond
    }

    func isStalled(
        at now: Date = .now,
        timeout: TimeInterval,
        isPaused: Bool
    ) -> Bool {
        !isPaused && now.timeIntervalSince(lastActivity) >= timeout
    }

    var isFinishing: Bool {
        ModelDownloadProgressPresentation.isFinishing(progress?.fractionCompleted ?? 0)
    }
}

enum ModelDownloadProgressPresentation {
    /// Xet can continue reconstructing model files after the measurable
    /// transfer estimate reaches its safe limit. Present that interval as a
    /// distinct finishing state instead of leaving a percentage visibly stuck.
    static let finishingThreshold = 0.95

    static func isFinishing(_ progress: Double) -> Bool {
        progress >= finishingThreshold
    }

    static func activePercentage(_ progress: Double) -> Int {
        let clampedProgress = min(max(progress, 0), 1)
        return min(Int((clampedProgress * 100).rounded(.down)), 99)
    }

    static func ringProgress(_ progress: Double) -> Double {
        min(max(progress, 0.025), 0.99)
    }

    static func formattedSpeed(
        _ bytesPerSecond: Double?,
        locale: Locale = .current
    ) -> String? {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return nil
        }
        let bytes = Int64(bytesPerSecond.rounded())
        guard bytes > 0 else { return "0 B/s" }
        return "\(formattedBytes(bytes, locale: locale))/s"
    }

    static func formattedByteProgress(
        _ progress: ModelDownloadProgress,
        locale: Locale = .current
    ) -> String? {
        guard let totalBytes = progress.totalBytes else { return nil }
        let completed = formattedBytes(progress.completedBytes, locale: locale)
        let total = formattedBytes(totalBytes, locale: locale)
        return "\(completed) / \(total)"
    }

    private static func formattedBytes(_ bytes: Int64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}

private final class HuggingFaceDownloadActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var state = HuggingFaceDownloadProgressState()

    func beginAttempt() {
        lock.withLock { state.beginAttempt() }
    }

    func resume() {
        lock.withLock { state.resume() }
    }

    func recordProgress(_ progress: ModelDownloadProgress) -> ModelDownloadProgress? {
        lock.withLock { state.recordProgress(progress) }
    }

    func recordTransferredBytes(_ bytes: Int64) -> ModelDownloadProgress? {
        lock.withLock { state.recordTransferredBytes(bytes) }
    }

    var bytesPerSecond: Double? {
        lock.withLock { state.transferSpeed() }
    }

    func isStalled(timeout: TimeInterval, isPaused: Bool) -> Bool {
        lock.withLock { state.isStalled(timeout: timeout, isPaused: isPaused) }
    }

    var isFinishing: Bool {
        lock.withLock { state.isFinishing }
    }
}

enum HuggingFaceDownloadOutput: Equatable {
    case progress(ModelDownloadProgress)
    case transferredBytes(Int64)
    case phase(HuggingFaceDownloadManager.DownloadPhase)

    init?(line: String) {
        if let payload = Self.payload(in: line, after: "__NATIV_PROGRESS__:"),
           let separator = payload.firstIndex(of: ":"),
           let completedBytes = Int64(payload[..<separator]),
           let totalBytes = Int64(payload[payload.index(after: separator)...]),
           let progress = ModelDownloadProgress(
               completedBytes: completedBytes,
               totalBytes: totalBytes
           ) {
            self = .progress(progress)
        } else if let payload = Self.payload(in: line, after: "__NATIV_TRANSFERRED__:"),
                  let bytes = Int64(payload) {
            self = .transferredBytes(max(bytes, 0))
        } else if let payload = Self.payload(in: line, after: "__NATIV_STAGE__:") {
            switch payload {
            case "preparing": self = .phase(.preparing)
            case "downloading": self = .phase(.downloading)
            case "finalizing": self = .phase(.finalizing)
            default: return nil
            }
        } else {
            return nil
        }
    }

    private static func payload(in line: String, after marker: String) -> Substring? {
        guard let markerRange = line.range(of: marker) else { return nil }
        return line[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)[...]
    }
}

private enum HuggingFaceDownloadAttemptError: Error {
    case stalled
}

private final class HuggingFaceCapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        if data.count > maximumBytes {
            data = Data(data.suffix(maximumBytes / 2))
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class HuggingFaceDownloadOperation: @unchecked Sendable {
    private static let stallTimeout: TimeInterval = 60
    private static let finalizationStallTimeout: TimeInterval = 10 * 60
    private static let monitorInterval: TimeInterval = 0.5
    private static let maximumAttempts = 3
    private static let maximumCapturedOutputBytes = 256 * 1024

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let progress: @Sendable (ModelDownloadProgress) -> Void
    private let transferSpeed: @Sendable (Double?) -> Void
    private let phase: @Sendable (HuggingFaceDownloadManager.DownloadPhase) -> Void
    private let activity = HuggingFaceDownloadActivity()
    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false
    private var isPaused = false

    init(
        repoID: String,
        cachePath: String,
        token: String?,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void,
        transferSpeed: @escaping @Sendable (Double?) -> Void,
        phase: @escaping @Sendable (HuggingFaceDownloadManager.DownloadPhase) -> Void
    ) throws {
        let distributionURL = try Nativ.distributionURL()
        let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw HuggingFaceHubError.pythonUnavailable
        }

        let script = """
        import os
        import sys
        import threading
        import time
        from huggingface_hub import snapshot_download
        from huggingface_hub.utils import tqdm

        parent_pid = int(sys.argv[3])

        def exit_if_parent_terminates():
            while os.getppid() == parent_pid:
                time.sleep(0.25)
            os._exit(0)

        threading.Thread(target=exit_if_parent_terminates, daemon=True).start()

        ignored_patterns = \(HuggingFaceDownloadFilePolicy.pythonListLiteral)
        total_bytes = 0
        cached_bytes = 0
        print("__NATIV_STAGE__:preparing", flush=True)
        try:
            files = snapshot_download(
                repo_id=sys.argv[1],
                cache_dir=sys.argv[2],
                dry_run=True,
                ignore_patterns=ignored_patterns,
            )
            total_bytes = sum(item.file_size for item in files)
            cached_bytes = sum(item.file_size for item in files if not item.will_download)
        except Exception:
            pass
        print(f"__NATIV_PROGRESS__:{cached_bytes}:{total_bytes}", flush=True)

        class NativProgress(tqdm):
            _lock = threading.Lock()
            _total_bytes = total_bytes
            _reconstructed_bytes = cached_bytes
            _transferred_bytes = 0
            _last_progress_report = 0.0
            _last_reported_progress = None
            _last_transfer_report = 0.0

            def __init__(self, *args, **kwargs):
                self._nativ_name = kwargs.get("name")
                kwargs["disable"] = True
                super().__init__(*args, **kwargs)

            def update(self, count=1):
                result = super().update(count)
                count = int(count or 0)
                if count == 0:
                    return result

                with NativProgress._lock:
                    now = time.monotonic()
                    if self._nativ_name == "huggingface_hub.snapshot_download":
                        observed_total = cached_bytes + int(self.total or 0)
                        NativProgress._total_bytes = max(
                            NativProgress._total_bytes,
                            observed_total,
                        )
                        NativProgress._reconstructed_bytes += count
                        NativProgress._emit_progress(now)
                    elif self._nativ_name == "huggingface_hub.snapshot_download.transfer":
                        NativProgress._transferred_bytes += count
                        NativProgress._emit_transfer(now)
                    else:
                        return result
                return result

            @classmethod
            def _emit_progress(cls, now):
                if cls._total_bytes <= 0:
                    return
                completed = min(max(cls._reconstructed_bytes, 0), cls._total_bytes)
                reported_progress = (completed, cls._total_bytes)
                if reported_progress == cls._last_reported_progress:
                    return
                is_complete = completed >= cls._total_bytes
                if not is_complete and now - cls._last_progress_report < 0.1:
                    return
                cls._last_progress_report = now
                cls._last_reported_progress = reported_progress
                print(
                    f"__NATIV_PROGRESS__:{completed}:{cls._total_bytes}",
                    flush=True,
                )

            @classmethod
            def _emit_transfer(cls, now):
                if now - cls._last_transfer_report < 0.1:
                    return
                cls._last_transfer_report = now
                print(f"__NATIV_TRANSFERRED__:{cls._transferred_bytes}", flush=True)

        print("__NATIV_STAGE__:downloading", flush=True)
        snapshot_download(
            repo_id=sys.argv[1],
            cache_dir=sys.argv[2],
            ignore_patterns=ignored_patterns,
            tqdm_class=NativProgress,
        )
        final_bytes = NativProgress._total_bytes
        print(f"__NATIV_PROGRESS__:{final_bytes}:{final_bytes}", flush=True)
        print("__NATIV_STAGE__:finalizing", flush=True)
        """

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = distributionURL.appendingPathComponent("python").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_CACHE"] = cachePath
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if let token = HuggingFaceAuthentication.normalizedToken(token) {
            environment[HuggingFaceAuthentication.environmentVariableName] = token
        }

        self.executableURL = pythonURL
        self.arguments = [
            "-c",
            script,
            repoID,
            cachePath,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        self.environment = environment
        self.progress = progress
        self.transferSpeed = transferSpeed
        self.phase = phase
    }

    func run() throws {
        for attempt in 1...Self.maximumAttempts {
            if isCancelled {
                throw CancellationError()
            }
            if attempt > 1 {
                phase(.retrying)
            }
            do {
                try runAttempt()
                return
            } catch HuggingFaceDownloadAttemptError.stalled {
                guard attempt < Self.maximumAttempts else {
                    throw HuggingFaceHubError.downloadStalled
                }
            }
        }
    }

    private func runAttempt() throws {
        activity.beginAttempt()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputGroup = DispatchGroup()
        let output = HuggingFaceCapturedOutput(
            maximumBytes: Self.maximumCapturedOutputBytes
        )
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            [activity, phase, progress] in
            var lineBuffer = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                guard !data.isEmpty else { break }

                output.append(data)

                lineBuffer += String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "\n")
                let lines = lineBuffer.components(separatedBy: "\n")
                lineBuffer = lines.last ?? ""
                for line in lines.dropLast() {
                    guard let output = HuggingFaceDownloadOutput(line: line) else { continue }
                    switch output {
                    case .progress(let reportedProgress):
                        if let updatedProgress = activity.recordProgress(reportedProgress) {
                            progress(updatedProgress)
                        }
                    case .transferredBytes(let bytes):
                        if let updatedProgress = activity.recordTransferredBytes(bytes) {
                            progress(updatedProgress)
                        }
                    case .phase(let downloadPhase):
                        phase(downloadPhase)
                    }
                }
            }
            outputGroup.leave()
        }

        lock.lock()
        self.process = process
        let cancelledBeforeLaunch = wasCancelled
        lock.unlock()
        if cancelledBeforeLaunch {
            try? pipe.fileHandleForWriting.close()
            outputGroup.wait()
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            clearProcess(process)
            outputGroup.wait()
            throw error
        }

        let flagsAfterLaunch = currentFlags
        if flagsAfterLaunch.cancelled {
            stopProcess(process)
        } else if flagsAfterLaunch.paused {
            Darwin.kill(process.processIdentifier, SIGSTOP)
        }

        var stalled = false
        while process.isRunning {
            let flags = currentFlags
            if flags.cancelled {
                stopProcess(process)
                break
            }
            if !flags.paused {
                transferSpeed(activity.bytesPerSecond)
                let timeout = activity.isFinishing
                    ? Self.finalizationStallTimeout
                    : Self.stallTimeout
                if activity.isStalled(timeout: timeout, isPaused: false) {
                    stalled = true
                    stopProcess(process)
                    break
                }
            }
            Thread.sleep(forTimeInterval: Self.monitorInterval)
        }

        process.waitUntilExit()
        clearProcess(process)
        outputGroup.wait()

        if isCancelled {
            throw CancellationError()
        }
        if stalled {
            throw HuggingFaceDownloadAttemptError.stalled
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: output.snapshot(), as: UTF8.self)
            throw HuggingFaceDownloadFailure(processOutput: message)
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let wasPaused = isPaused
        isPaused = false
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            if wasPaused {
                Darwin.kill(process.processIdentifier, SIGCONT)
            }
            process.terminate()
        }
    }

    func waitForExit(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while currentProcess?.isRunning == true, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        guard let process = currentProcess, process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)

        let forcedExitDeadline = clock.now.advanced(by: .seconds(1))
        while process.isRunning, clock.now < forcedExitDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func pause() {
        lock.lock()
        isPaused = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGSTOP)
        }
    }

    func resume() {
        lock.lock()
        isPaused = false
        let process = self.process
        lock.unlock()
        activity.resume()
        if let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGCONT)
        }
    }

    private var currentFlags: (cancelled: Bool, paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (wasCancelled, isPaused)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasCancelled
    }

    private var currentProcess: Process? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }

    private func clearProcess(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    private func stopProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

}
