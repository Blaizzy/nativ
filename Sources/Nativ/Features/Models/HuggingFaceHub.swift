import Darwin
import Foundation
import NativServerKit

enum HuggingFaceModelSort: String, CaseIterable, Identifiable, Sendable {
    case downloads
    case trending = "trendingScore"
    case likes
    case recentlyUpdated = "lastModified"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .trending: "Trending"
        case .likes: "Likes"
        case .recentlyUpdated: "Recently Updated"
        }
    }

    var systemImage: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .trending: "flame"
        case .likes: "heart"
        case .recentlyUpdated: "clock.arrow.circlepath"
        }
    }

    var hubWebValue: String {
        switch self {
        case .downloads: "downloads"
        case .trending: "trending"
        case .likes: "likes"
        case .recentlyUpdated: "modified"
        }
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
    }

    var provider: LocalModelProvider? {
        LocalModelProviderResolver.resolve(repoID: id, modelType: nil, architectures: [])
    }

    var sizeBytes: Int64? {
        safetensors?.sizeBytes
    }

    var memoryEstimate: LocalModelMemoryEstimate? {
        guard let safetensors,
              safetensors.hasOnlyKnownDataTypes,
              let sizeBytes = safetensors.sizeBytes,
              sizeBytes > 0
        else {
            return nil
        }

        let parameterCount = LocalModelDiscovery.parameterCount(from: id)
        let quantizationBits = LocalModelDiscovery.quantizationBits(from: id)
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
            totalMemoryBytes: totalMemoryBytes
        )
    }

    var capabilities: Set<LocalModelCapability> {
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
        }
    }
}

private struct HuggingFaceHubClient: Sendable {
    func search(query: String, sort: HuggingFaceModelSort) async throws -> HuggingFaceModelPage {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"

        var queryItems = [
            URLQueryItem(name: "filter", value: "safetensors"),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "50")
        ]
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

        return try await page(at: url)
    }

    func page(at url: URL) async throws -> HuggingFaceModelPage {

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("MLXPlatform/1.0", forHTTPHeaderField: "User-Agent")
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
    private var cachedPages: [HuggingFaceModelPage] = []
    private let maximumPageCount = 5

    deinit {
        searchTask?.cancel()
    }

    func search(query: String, sort: HuggingFaceModelSort) {
        searchTask?.cancel()
        isSearching = true
        error = nil
        models = []
        cachedPages = []
        pageNumber = 1

        searchTask = Task { [weak self, client] in
            do {
                let page = try await client.search(query: query, sort: sort)
                try Task.checkCancellation()
                self?.cachedPages = [page]
                self?.models = page.models
                self?.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.models = []
                self?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    var canGoToPreviousPage: Bool {
        pageNumber > 1 && !isSearching
    }

    var canGoToNextPage: Bool {
        guard !isSearching, pageNumber < maximumPageCount else { return false }
        if pageNumber < cachedPages.count {
            return true
        }
        return cachedPages.last?.nextPageURL != nil
    }

    func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        pageNumber -= 1
        models = cachedPages[pageNumber - 1].models
        error = nil
    }

    func goToNextPage() {
        guard canGoToNextPage else { return }

        if pageNumber < cachedPages.count {
            pageNumber += 1
            models = cachedPages[pageNumber - 1].models
            error = nil
            return
        }

        guard let nextPageURL = cachedPages.last?.nextPageURL else { return }
        searchTask?.cancel()
        isSearching = true
        error = nil

        searchTask = Task { [weak self, client] in
            do {
                let page = try await client.page(at: nextPageURL)
                try Task.checkCancellation()
                self?.cachedPages.append(page)
                self?.pageNumber += 1
                self?.models = page.models
                self?.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}

@MainActor
final class HuggingFaceDownloadManager: ObservableObject {
    @Published private(set) var downloadingModelID: String?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var isDownloadPaused = false
    @Published private(set) var errorByModelID: [String: String] = [:]

    private var downloadTask: Task<Void, Never>?
    private var activeOperation: HuggingFaceDownloadOperation?
    private var activeCachePath: String?
    private var activeCompletion: (() -> Void)?

    deinit {
        downloadTask?.cancel()
    }

    func download(repoID: String, cachePath: String, onCompletion: @escaping () -> Void) {
        guard downloadingModelID == nil else { return }
        downloadingModelID = repoID
        downloadProgress = 0
        isDownloadPaused = false
        errorByModelID[repoID] = nil
        activeCachePath = LocalModelDiscovery.expandedPath(cachePath)
        activeCompletion = onCompletion

        startActiveDownload()
    }

    func pauseDownload() {
        guard downloadingModelID != nil, !isDownloadPaused else { return }
        activeOperation?.pause()
        isDownloadPaused = true
    }

    func resumeDownload() {
        guard downloadingModelID != nil, isDownloadPaused else { return }
        activeOperation?.resume()
        isDownloadPaused = false
    }

    func removeDownload() {
        guard let repoID = downloadingModelID, let cachePath = activeCachePath else { return }
        let task = downloadTask
        task?.cancel()
        downloadTask = nil
        clearActiveDownload()

        Task {
            await task?.value
            await Task.detached(priority: .utility) {
                HuggingFaceSnapshotDownloader.removeDownload(repoID: repoID, cachePath: cachePath)
            }.value
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        clearActiveDownload()
    }

    private func startActiveDownload() {
        guard let repoID = downloadingModelID, let cachePath = activeCachePath else { return }

        let operation: HuggingFaceDownloadOperation
        do {
            operation = try HuggingFaceDownloadOperation(
                repoID: repoID,
                cachePath: cachePath
            ) { progress in
                Task { @MainActor [weak self] in
                    guard self?.downloadingModelID == repoID else { return }
                    self?.downloadProgress = progress
                }
            }
            activeOperation = operation
        } catch {
            errorByModelID[repoID] =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            clearActiveDownload()
            return
        }

        downloadTask = Task { [weak self] in
            do {
                try await HuggingFaceSnapshotDownloader.download(operation: operation)
                guard !Task.isCancelled else { return }
                self?.downloadProgress = 1
                let completion = self?.activeCompletion
                self?.clearActiveDownload()
                completion?()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorByModelID[repoID] =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.clearActiveDownload()
            }
        }
    }

    private func clearActiveDownload() {
        downloadingModelID = nil
        downloadProgress = 0
        isDownloadPaused = false
        activeOperation = nil
        activeCachePath = nil
        activeCompletion = nil
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
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let distributionURL = try Nativ.distributionURL()
        let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw HuggingFaceHubError.pythonUnavailable
        }

        let script = """
        import sys
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
                if abs(progress - self._mlx_last_progress) >= 0.002 or progress >= 1.0:
                    self._mlx_last_progress = progress
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
