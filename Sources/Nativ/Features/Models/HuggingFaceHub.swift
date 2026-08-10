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

struct HuggingFaceModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let downloads: Int
    let likes: Int
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

    enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags
        case isPrivate = "private"
        case gated
        case safetensors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        safetensors = try container.decodeIfPresent(HuggingFaceSafetensors.self, forKey: .safetensors)

        if let value = try? container.decode(Bool.self, forKey: .gated) {
            isGated = value
        } else if let value = try? container.decode(String.self, forKey: .gated) {
            isGated = !value.isEmpty && value != "false"
        } else {
            isGated = false
        }

        provider = LocalModelProviderResolver.resolve(repoID: id, modelType: nil, architectures: [])
        sizeBytes = safetensors?.sizeBytes
        capabilities = Self.resolveCapabilities(
            pipelineTag: pipelineTag,
            libraryName: libraryName,
            tags: tags
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
        tags: [String]
    ) -> Set<LocalModelCapability> {
        let pipeline = pipelineTag?.lowercased() ?? ""
        let descriptors = ([pipelineTag, libraryName].compactMap { $0 } + tags)
            .joined(separator: " ")
            .lowercased()
        var result = Set<LocalModelCapability>()

        let textPipelines: Set<String> = [
            "text-generation", "image-text-to-text", "image-to-text",
            "video-text-to-text", "any-to-any", "translation"
        ]
        if textPipelines.contains(pipeline)
            || descriptors.contains("conversational")
            || descriptors.contains("causal-lm") {
            result.insert(.text)
        }

        if pipeline.contains("image-text")
            || pipeline == "image-to-text"
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
        if pipeline == "image-to-image" {
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
            "feature-extraction", "sentence-similarity", "text-ranking"
        ]
        if embeddingPipelines.contains(pipeline)
            || descriptors.contains("embedding")
            || descriptors.contains("sentence-transformers") {
            result.insert(.embeddings)
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
    case downloadFailed(String)
    case anotherDownloadInProgress(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Hugging Face returned an invalid response."
        case .requestFailed(let status, let message):
            message.isEmpty ? "Hugging Face request failed (HTTP \(status))." : message
        case .pythonUnavailable:
            "The bundled model downloader is unavailable."
        case .downloadFailed(let message):
            message.isEmpty ? "The model download failed." : message
        case .anotherDownloadInProgress(let modelID):
            "Wait for \(modelID) to finish downloading before starting another model download."
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
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"

        var queryItems = [
            URLQueryItem(name: "filter", value: "safetensors"),
            URLQueryItem(name: "sort", value: sort.apiSortValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "50")
        ]
        if let pipelineTag = Self.pipelineTag(for: capabilities) {
            queryItems.append(URLQueryItem(name: "pipeline_tag", value: pipelineTag))
        }
        queryItems.append(contentsOf: [
            "downloads", "likes", "pipeline_tag", "library_name", "tags",
            "private", "gated", "safetensors"
        ].map { URLQueryItem(name: "expand[]", value: $0) })
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: trimmedQuery))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw HuggingFaceHubError.invalidResponse
        }

        return try await page(at: url, token: token)
    }

    private static func pipelineTag(for capabilities: Set<LocalModelCapability>) -> String? {
        guard capabilities.count == 1, let capability = capabilities.first else {
            return nil
        }
        switch capability {
        case .imageGeneration:
            return "text-to-image"
        case .imageEditing:
            return "image-to-image"
        case .speechToText:
            return "automatic-speech-recognition"
        case .textToSpeech:
            return "text-to-speech"
        case .vision:
            return "image-text-to-text"
        case .text, .audio, .video, .embeddings, .reasoning, .tools, .drafter:
            return nil
        }
    }

    func model(id: String, token: String?) async throws -> HuggingFaceModel {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(id)"
        components.queryItems = [
            "downloads", "likes", "pipeline_tag", "library_name", "tags",
            "private", "gated", "safetensors"
        ].map { URLQueryItem(name: "expand[]", value: $0) }

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
        return try JSONDecoder().decode(HuggingFaceModel.self, from: data)
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
                    && !$0.capabilities.contains(.embeddings)
            }
        return HuggingFaceModelPage(
            models: models,
            nextPageURL: nextPageURL(from: httpResponse.value(forHTTPHeaderField: "Link"))
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
}

private struct HuggingFaceModelPage: Sendable {
    let models: [HuggingFaceModel]
    let nextPageURL: URL?
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
    private var visibilityPredicate: (HuggingFaceModel) -> Bool = { _ in true }
    private var nextPageURL: URL?
    private let pageSize = 24
    private let maximumPageCount = 5
    private let maximumFillFetches = 8

    deinit {
        searchTask?.cancel()
    }

    func search(
        query: String,
        sort: HuggingFaceModelSort,
        capabilities: Set<LocalModelCapability>,
        predicate: @escaping (HuggingFaceModel) -> Bool,
        token: String?
    ) {
        searchTask?.cancel()
        isSearching = true
        error = nil
        models = []
        buffer = []
        nextPageURL = nil
        pageNumber = 1
        activeSort = sort
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
                self.buffer = page.models
                self.nextPageURL = page.nextPageURL
                try await self.fillBuffer(upTo: self.pageSize, token: token)
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
        nextPageURL = nil
        pageNumber = 1
        activeSort = .downloads
        visibilityPredicate = { _ in true }

        searchTask = Task { [weak self] in
            guard let self else { return }
            var fetched: [String: HuggingFaceModel] = [:]
            await withTaskGroup(of: (String, HuggingFaceModel?).self) { group in
                let client = self.client
                for id in ids {
                    group.addTask {
                        do {
                            return (id, try await client.model(id: id, token: token))
                        } catch {
                            return (id, nil)
                        }
                    }
                }
                for await (id, model) in group where model != nil {
                    fetched[id] = model
                }
            }
            guard !Task.isCancelled else { return }
            let ordered = ids.compactMap { fetched[$0] }
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
        return orderedVisible.count > pageNumber * pageSize || nextPageURL != nil
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

        if orderedVisible.count >= target * pageSize || nextPageURL == nil {
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
        var fetches = 0
        while orderedVisible.count < count, let url = nextPageURL, fetches < maximumFillFetches {
            let nextPage = try await client.page(at: url, token: token)
            try Task.checkCancellation()
            buffer.append(contentsOf: nextPage.models)
            nextPageURL = nextPage.nextPageURL
            fetches += 1
        }
    }

    private func slice(forPage number: Int) -> [HuggingFaceModel] {
        let ordered = orderedVisible
        let start = (number - 1) * pageSize
        guard start < ordered.count else { return [] }
        return Array(ordered[start..<min(start + pageSize, ordered.count)])
    }

    /// Buffered results in display order; `.size` re-sorts locally (smallest first).
    private var orderedBuffer: [HuggingFaceModel] {
        guard activeSort.sortsBySize else { return buffer }
        return buffer.sorted { lhs, rhs in
            switch (lhs.sizeBytes, rhs.sizeBytes) {
            case let (lhsSize?, rhsSize?): return lhsSize < rhsSize
            case (nil, _): return false
            case (_, nil): return true
            }
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

@MainActor
final class HuggingFaceDownloadManager: ObservableObject {
    static let shared = HuggingFaceDownloadManager()

    enum DownloadState: Equatable {
        case downloading
        case paused
    }

    struct RowSnapshot: Equatable {
        let isDownloading: Bool
        let progress: Double
        let isPaused: Bool
        let error: String?
    }

    struct ActiveDownload: Identifiable, Equatable {
        let modelID: String
        let sizeBytes: Int64?
        var progress: Double
        var state: DownloadState

        var id: String { modelID }
    }

    private final class DownloadContext {
        let modelID: String
        let cachePath: String
        let token: String?
        var onCompletion: (() -> Void)?
        var operation: HuggingFaceDownloadOperation?
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

        init(modelID: String, cachePath: String, token: String?, onCompletion: (() -> Void)?) {
            self.modelID = modelID
            self.cachePath = cachePath
            self.token = token
            self.onCompletion = onCompletion
        }
    }

    @Published private(set) var downloads: [ActiveDownload] = []
    @Published private(set) var errorByModelID: [String: String] = [:]
    /// Emits the affected model ID for progress/state changes. `nil` denotes
    /// a structural change that can affect capacity for every download row.
    let rowUpdates = PassthroughSubject<String?, Never>()

    private var contexts: [String: DownloadContext] = [:]
    private var progressUpdateTimes: [String: Date] = [:]
    private var freeDiskCache: [String: (timestamp: Date, bytes: Int64?)] = [:]

    deinit {
        contexts.values.forEach { $0.task?.cancel() }
    }

    var activeCount: Int { downloads.count }

    var reservedBytes: Int64 {
        downloads.reduce(Int64(0)) { total, download in
            guard let sizeBytes = download.sizeBytes else { return total }
            let remaining = Double(sizeBytes) * (1 - download.progress)
            guard remaining > 0 else { return total }
            return total + Int64(remaining)
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
        errorByModelID[modelID] = message
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
        token: String?,
        onCompletion: @escaping () -> Void
    ) {
        guard contexts[repoID] == nil else { return }
        if let blocker = capacityBlocker(sizeBytes: sizeBytes, cachePath: cachePath) {
            errorByModelID[repoID] = blocker
            rowUpdates.send(repoID)
            return
        }
        do {
            try enqueue(
                repoID: repoID,
                sizeBytes: sizeBytes,
                cachePath: cachePath,
                token: token,
                onCompletion: onCompletion
            )
        } catch {
            errorByModelID[repoID] =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            rowUpdates.send(repoID)
        }
    }

    func downloadIfNeeded(
        repoID: String,
        sizeBytes: Int64?,
        cachePath: String,
        token: String?
    ) async throws {
        let expandedCachePath = LocalModelDiscovery.expandedPath(cachePath)
        if let context = contexts[repoID] {
            guard context.cachePath == expandedCachePath else {
                throw HuggingFaceHubError.anotherDownloadInProgress(repoID)
            }
        } else {
            do {
                try enqueue(
                    repoID: repoID,
                    sizeBytes: sizeBytes,
                    cachePath: expandedCachePath,
                    token: token,
                    onCompletion: nil
                )
            } catch {
                errorByModelID[repoID] =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        context.operation?.resume()
        setState(modelID, .downloading)
    }

    func removeDownload(_ modelID: String) {
        guard let context = contexts[modelID] else { return }
        let task = context.task
        let cachePath = context.cachePath
        task?.cancel()
        let waiters = Array(context.waiters.values)
        removeContext(modelID)
        waiters.forEach { $0.resume(throwing: CancellationError()) }

        Task {
            await task?.value
            await Task.detached(priority: .utility) {
                HuggingFaceSnapshotDownloader.removeDownload(repoID: modelID, cachePath: cachePath)
            }.value
        }
    }

    private func enqueue(
        repoID: String,
        sizeBytes: Int64?,
        cachePath: String,
        token: String?,
        onCompletion: (() -> Void)?
    ) throws {
        let expandedCachePath = LocalModelDiscovery.expandedPath(cachePath)
        let context = DownloadContext(
            modelID: repoID,
            cachePath: expandedCachePath,
            token: token,
            onCompletion: onCompletion
        )
        contexts[repoID] = context
        errorByModelID[repoID] = nil
        downloads.append(
            ActiveDownload(modelID: repoID, sizeBytes: sizeBytes, progress: 0, state: .downloading)
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
            token: normalizedToken
        ) { progress in
            Task { @MainActor [weak self] in
                self?.updateProgress(repoID, progress)
            }
        }

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
            errorByModelID[repoID] =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private func updateProgress(_ modelID: String, _ progress: Double) {
        guard contexts[modelID] != nil,
              let index = downloads.firstIndex(where: { $0.modelID == modelID })
        else {
            return
        }
        let clampedProgress = min(max(progress, 0), 1)
        let previousProgress = downloads[index].progress
        let now = Date()
        let lastUpdate = progressUpdateTimes[modelID] ?? .distantPast

        // Python reports byte progress frequently. Coalesce those reports on
        // the main actor so a download does not invalidate every visible row
        // (and the scroll view) for tiny, visually indistinguishable changes.
        guard clampedProgress >= 1
            || clampedProgress - previousProgress >= 0.01
            || now.timeIntervalSince(lastUpdate) >= 0.10
        else {
            return
        }
        downloads[index].progress = clampedProgress
        progressUpdateTimes[modelID] = now
        rowUpdates.send(modelID)
    }

    private func setState(_ modelID: String, _ state: DownloadState) {
        guard let index = downloads.firstIndex(where: { $0.modelID == modelID }) else { return }
        downloads[index].state = state
        rowUpdates.send(modelID)
    }

    private func removeContext(_ modelID: String) {
        contexts.removeValue(forKey: modelID)
        downloads.removeAll { $0.modelID == modelID }
        progressUpdateTimes.removeValue(forKey: modelID)
        rowUpdates.send(nil)
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

    static func removeDownload(repoID: String, cachePath: String) {
        let repositoryDirectory = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let cacheURL = URL(fileURLWithPath: cachePath, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: cacheURL.appendingPathComponent(repositoryDirectory, isDirectory: true))
        try? fileManager.removeItem(
            at: cacheURL
                .appendingPathComponent(".locks", isDirectory: true)
                .appendingPathComponent(repositoryDirectory, isDirectory: true)
        )
    }
}

private final class HuggingFaceDownloadOperation: @unchecked Sendable {
    private let process: Process
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var wasCancelled = false
    private var isPaused = false

    init(
        repoID: String,
        cachePath: String,
        token: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let distributionURL = try Nativ.distributionURL()
        let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw HuggingFaceHubError.pythonUnavailable
        }

        let script = """
        import sys
        import time
        from tqdm.auto import tqdm
        from huggingface_hub import snapshot_download

        expected_bytes = 0
        try:
            pending_files = snapshot_download(
                repo_id=sys.argv[1],
                cache_dir=sys.argv[2],
                dry_run=True,
            )
            expected_bytes = sum(
                item.file_size for item in pending_files if item.will_download
            )
        except Exception:
            pass

        class MLXProgressTqdm(tqdm):
            def __init__(self, *args, **kwargs):
                self._mlx_reports_bytes = kwargs.get("unit") == "B"
                self._mlx_last_progress = -1.0
                self._mlx_last_report = 0.0
                super().__init__(*args, **kwargs)
                self._mlx_report()

            def update(self, n=1):
                result = super().update(n)
                self._mlx_report()
                return result

            def refresh(self, *args, **kwargs):
                result = super().refresh(*args, **kwargs)
                self._mlx_report()
                return result

            def _mlx_report(self):
                if not self._mlx_reports_bytes:
                    return
                total = float(expected_bytes or self.total or 0)
                value = float(self.n or 0)
                progress = min(max(value / total, 0.0), 1.0) if total > 0 else 0.0
                now = time.monotonic()
                changed = abs(progress - self._mlx_last_progress)
                stale = now - self._mlx_last_report >= 0.25
                if progress >= 1.0 or changed >= 0.002 or (changed > 0.0 and stale):
                    self._mlx_last_progress = progress
                    self._mlx_last_report = now
                    print(f"__MLX_PROGRESS__:{progress:.6f}", flush=True)

        snapshot_download(
            repo_id=sys.argv[1],
            cache_dir=sys.argv[2],
            tqdm_class=MLXProgressTqdm,
        )
        """

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", script, repoID, cachePath]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONHOME"] = distributionURL.appendingPathComponent("python").path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_CACHE"] = cachePath
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if let token = HuggingFaceAuthentication.normalizedToken(token) {
            environment[HuggingFaceAuthentication.environmentVariableName] = token
        }
        process.environment = environment
        self.process = process
        self.progress = progress
    }

    func run() throws {
        lock.lock()
        let cancelledBeforeLaunch = wasCancelled
        lock.unlock()
        if cancelledBeforeLaunch {
            throw CancellationError()
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputGroup = DispatchGroup()
        let outputLock = NSLock()
        var output = Data()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async { [progress] in
            var lineBuffer = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                guard !data.isEmpty else { break }

                outputLock.lock()
                output.append(data)
                outputLock.unlock()

                lineBuffer += String(decoding: data, as: UTF8.self)
                let lines = lineBuffer.components(separatedBy: "\n")
                lineBuffer = lines.last ?? ""
                for line in lines.dropLast() {
                    guard let markerRange = line.range(of: "__MLX_PROGRESS__:") else { continue }
                    let value = line[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fraction = Double(value) {
                        progress(min(max(fraction, 0), 1))
                    }
                }
            }
            outputGroup.leave()
        }

        do {
            try process.run()
            lock.lock()
            let cancelledAfterLaunch = wasCancelled
            let pausedAfterLaunch = isPaused
            lock.unlock()
            if cancelledAfterLaunch {
                process.terminate()
            } else if pausedAfterLaunch {
                Darwin.kill(process.processIdentifier, SIGSTOP)
            }
        } catch {
            try? pipe.fileHandleForWriting.close()
            outputGroup.wait()
            throw error
        }
        process.waitUntilExit()
        outputGroup.wait()

        lock.lock()
        let cancelled = wasCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            outputLock.lock()
            let message = String(decoding: output, as: UTF8.self)
            outputLock.unlock()
            let usefulMessage = message
                .split(separator: "\n")
                .suffix(4)
                .joined(separator: "\n")
            throw HuggingFaceHubError.downloadFailed(usefulMessage)
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let wasPaused = isPaused
        isPaused = false
        let shouldTerminate = process.isRunning
        lock.unlock()
        if shouldTerminate, wasPaused {
            Darwin.kill(process.processIdentifier, SIGCONT)
        }
        if shouldTerminate {
            process.terminate()
        }
    }

    func pause() {
        lock.lock()
        isPaused = true
        let shouldPause = process.isRunning
        lock.unlock()
        if shouldPause {
            Darwin.kill(process.processIdentifier, SIGSTOP)
        }
    }

    func resume() {
        lock.lock()
        isPaused = false
        let shouldResume = process.isRunning
        lock.unlock()
        if shouldResume {
            Darwin.kill(process.processIdentifier, SIGCONT)
        }
    }
}
