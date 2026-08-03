import Combine
import Foundation
import NativServerKit

struct HuggingFaceRepoFile: Decodable, Equatable, Sendable {
    let rfilename: String
}

struct HuggingFaceBaseModelReference: Decodable, Equatable, Sendable {
    let id: String
}

struct HuggingFaceBaseModels: Decodable, Equatable, Sendable {
    let relation: String?
    let models: [HuggingFaceBaseModelReference]
}

struct HuggingFaceLoRAAdapter: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let sha: String
    let downloads: Int
    let likes: Int
    let tags: [String]
    let libraryName: String?
    let isPrivate: Bool
    let isGated: Bool
    let siblings: [HuggingFaceRepoFile]
    let baseModels: HuggingFaceBaseModels?

    enum CodingKeys: String, CodingKey {
        case id, sha, downloads, likes, tags, siblings, gated
        case isPrivate = "private"
        case baseModels
        case libraryName = "library_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sha = try container.decode(String.self, forKey: .sha)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        siblings = try container.decodeIfPresent(
            [HuggingFaceRepoFile].self,
            forKey: .siblings
        ) ?? []
        baseModels = try container.decodeIfPresent(
            HuggingFaceBaseModels.self,
            forKey: .baseModels
        )

        if let value = try? container.decode(Bool.self, forKey: .gated) {
            isGated = value
        } else if let value = try? container.decode(String.self, forKey: .gated) {
            isGated = !value.isEmpty && value != "false"
        } else {
            isGated = false
        }
    }

    var artifactVariants: [LoRAAdapterArtifactVariant] {
        let paths = Set(siblings.map(\.rfilename))
        return paths.compactMap { configPath -> LoRAAdapterArtifactVariant? in
            guard configPath == "adapter_config.json"
                    || configPath.hasSuffix("/adapter_config.json")
            else {
                return nil
            }
            let subfolder = configPath == "adapter_config.json"
                ? ""
                : String(configPath.dropLast("/adapter_config.json".count))
            guard !Self.isCheckpointSubfolder(subfolder) else {
                return nil
            }
            let nativeWeightsPath = subfolder.isEmpty
                ? "adapters.safetensors"
                : "\(subfolder)/adapters.safetensors"
            let peftWeightsPath = subfolder.isEmpty
                ? "adapter_model.safetensors"
                : "\(subfolder)/adapter_model.safetensors"
            let format: LoRAAdapterPackageFormat
            let weightsPath: String
            if libraryName?.lowercased() == "peft", paths.contains(peftWeightsPath) {
                format = .peft
                weightsPath = peftWeightsPath
            } else if paths.contains(nativeWeightsPath) {
                format = .nativeMLX
                weightsPath = nativeWeightsPath
            } else if paths.contains(peftWeightsPath) {
                format = .peft
                weightsPath = peftWeightsPath
            } else {
                return nil
            }
            return LoRAAdapterArtifactVariant(
                reference: HubLoRAAdapterReference(
                    repoID: id,
                    revisionSHA: sha,
                    subfolder: subfolder
                ),
                configPath: configPath,
                weightsPath: weightsPath,
                format: format
            )
        }
        .sorted { lhs, rhs in
            let lhsPriority = Self.variantPriority(lhs.reference.subfolder)
            let rhsPriority = Self.variantPriority(rhs.reference.subfolder)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.reference.subfolder != rhs.reference.subfolder {
                return lhs.reference.subfolder < rhs.reference.subfolder
            }
            return lhs.weightsPath < rhs.weightsPath
        }
    }

    func declaresAdapterRelationship(to baseModelID: String) -> Bool {
        if baseModels?.relation == "adapter",
           baseModels?.models.contains(where: { $0.id == baseModelID }) == true {
            return true
        }
        return tags.contains("base_model:adapter:\(baseModelID)")
    }

    private static func isCheckpointSubfolder(_ subfolder: String) -> Bool {
        subfolder.split(separator: "/").contains { component in
            component.lowercased().contains("checkpoint")
        }
    }

    private static func variantPriority(_ subfolder: String) -> Int {
        switch subfolder.lowercased() {
        case "mlx": 0
        case "": 1
        case "adapter": 2
        default: 3
        }
    }
}

struct HuggingFaceLoRAAdapterListItem: Identifiable, Equatable, Sendable {
    let adapter: HuggingFaceLoRAAdapter
    let variant: LoRAAdapterArtifactVariant

    var id: LoRAAdapterSlot { variant.reference.slot }
}

struct HuggingFaceLoRAAdapterUpdate: Identifiable, Equatable, Sendable {
    let installed: InstalledLoRAAdapter
    let available: HuggingFaceLoRAAdapterListItem

    var id: LoRAAdapterSlot { available.id }
}

/// An immutable, deterministic projection used by the adapter sheet. The two
/// sections are mutually exclusive and every conceptual adapter slot appears once.
struct LoRAAdapterListSnapshot: Equatable, Sendable {
    let installed: [InstalledLoRAAdapter]
    let updates: [HuggingFaceLoRAAdapterUpdate]
    let available: [HuggingFaceLoRAAdapterListItem]

    init(
        installed candidates: [InstalledLoRAAdapter],
        remoteAdapters: [HuggingFaceLoRAAdapter],
        activeReference: HubLoRAAdapterReference?
    ) {
        var installedBySlot: [LoRAAdapterSlot: InstalledLoRAAdapter] = [:]
        for candidate in candidates {
            let slot = candidate.reference.slot
            guard let existing = installedBySlot[slot] else {
                installedBySlot[slot] = candidate
                continue
            }
            if candidate.reference == activeReference {
                installedBySlot[slot] = candidate
            } else if existing.reference != activeReference,
                      candidate.installedAt > existing.installedAt {
                installedBySlot[slot] = candidate
            }
        }

        installed = installedBySlot.values.sorted { lhs, rhs in
            let lhsIsActive = lhs.reference == activeReference
            let rhsIsActive = rhs.reference == activeReference
            if lhsIsActive != rhsIsActive { return lhsIsActive }
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if lhs.reference.repoID != rhs.reference.repoID {
                return lhs.reference.repoID < rhs.reference.repoID
            }
            return lhs.reference.subfolder < rhs.reference.subfolder
        }

        var remoteBySlot: [LoRAAdapterSlot: HuggingFaceLoRAAdapterListItem] = [:]
        for adapter in remoteAdapters {
            for variant in adapter.artifactVariants {
                let item = HuggingFaceLoRAAdapterListItem(
                    adapter: adapter,
                    variant: variant
                )
                guard remoteBySlot[item.id] == nil else { continue }
                remoteBySlot[item.id] = item
            }
        }

        updates = remoteBySlot.compactMap { slot, item in
            guard let installedAdapter = installedBySlot[slot],
                  installedAdapter.reference != item.variant.reference
            else { return nil }
            return HuggingFaceLoRAAdapterUpdate(
                installed: installedAdapter,
                available: item
            )
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.installed.displayName.localizedCaseInsensitiveCompare(
                rhs.installed.displayName
            )
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.id < rhs.id.id
        }

        let installedSlots = Set(installedBySlot.keys)
        let availableBySlot = remoteBySlot.filter { !installedSlots.contains($0.key) }

        available = availableBySlot.values.sorted { lhs, rhs in
            if lhs.adapter.downloads != rhs.adapter.downloads {
                return lhs.adapter.downloads > rhs.adapter.downloads
            }
            if lhs.adapter.likes != rhs.adapter.likes {
                return lhs.adapter.likes > rhs.adapter.likes
            }
            let repoOrder = lhs.adapter.id.localizedCaseInsensitiveCompare(rhs.adapter.id)
            if repoOrder != .orderedSame { return repoOrder == .orderedAscending }
            return lhs.variant.reference.subfolder < rhs.variant.reference.subfolder
        }
    }
}

struct LoRAAdapterArtifactVariant: Identifiable, Equatable, Sendable {
    let reference: HubLoRAAdapterReference
    let configPath: String
    let weightsPath: String
    let format: LoRAAdapterPackageFormat

    /// Creates only artifact combinations that Nativ's MLX runtime can validate
    /// and load. This allowlist intentionally excludes GGUF and every other
    /// container format instead of relying on repository tags or extension checks.
    init?(
        reference: HubLoRAAdapterReference,
        configPath: String,
        weightsPath: String,
        format: LoRAAdapterPackageFormat
    ) {
        let prefix = reference.subfolder.isEmpty ? "" : "\(reference.subfolder)/"
        guard configPath == "\(prefix)adapter_config.json",
              weightsPath == "\(prefix)\(format.weightsFileName)"
        else {
            return nil
        }
        self.reference = reference
        self.configPath = configPath
        self.weightsPath = weightsPath
        self.format = format
    }

    var id: String { reference.id }

    var formatLabel: String {
        let formatName = format == .peft ? "PEFT" : "MLX"
        return reference.subfolder.isEmpty
            ? formatName
            : "\(formatName) · \(reference.subfolder)"
    }
}

private struct HuggingFaceErrorPayload: Decodable {
    let error: String
}

private struct HuggingFaceRepoPathInfo: Decodable {
    let type: String
    let path: String
    let size: Int64?
}

struct HuggingFaceLoRAAdapterClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(
        baseModelID: String,
        query: String,
        token: String?
    ) async throws -> [HuggingFaceLoRAAdapter] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models"
        var queryItems = [
            URLQueryItem(name: "filter", value: "base_model:adapter:\(baseModelID)"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        queryItems.append(contentsOf: [
            "sha", "baseModels", "siblings", "tags", "downloads", "likes",
            "gated", "private", "library_name",
        ].map { URLQueryItem(name: "expand[]", value: $0) })
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: Self.searchTerm(trimmedQuery)))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw HuggingFaceHubError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Nativ/1.0", forHTTPHeaderField: "User-Agent")
        HuggingFaceAuthentication.authorize(&request, token: token)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HuggingFaceHubError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(
                HuggingFaceErrorPayload.self,
                from: data
            ))?.error ?? ""
            throw HuggingFaceHubError.requestFailed(response.statusCode, message)
        }

        return try JSONDecoder().decode([HuggingFaceLoRAAdapter].self, from: data)
            .filter { adapter in
                adapter.declaresAdapterRelationship(to: baseModelID)
                    && !adapter.artifactVariants.isEmpty
            }
    }

    func artifactSize(
        adapter: HuggingFaceLoRAAdapter,
        variant: LoRAAdapterArtifactVariant,
        token: String?
    ) async throws -> Int64 {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path =
            "/api/models/\(adapter.id)/paths-info/\(variant.reference.revisionSHA)"
        guard let url = components.url else {
            throw HuggingFaceHubError.invalidResponse
        }

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "paths", value: variant.configPath),
            URLQueryItem(name: "paths", value: variant.weightsPath),
            URLQueryItem(name: "expand", value: "false"),
        ]
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
            throw HuggingFaceHubError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("Nativ/1.0", forHTTPHeaderField: "User-Agent")
        HuggingFaceAuthentication.authorize(&request, token: token)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HuggingFaceHubError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(
                HuggingFaceErrorPayload.self,
                from: data
            ))?.error ?? ""
            throw HuggingFaceHubError.requestFailed(response.statusCode, message)
        }

        return try Self.combinedArtifactSize(
            from: data,
            expectedPaths: [variant.configPath, variant.weightsPath]
        )
    }

    static func combinedArtifactSize(
        from data: Data,
        expectedPaths: [String]
    ) throws -> Int64 {
        let paths = try JSONDecoder().decode([HuggingFaceRepoPathInfo].self, from: data)
        var fileSizes: [String: Int64] = [:]
        for item in paths {
            if item.type == "file", let size = item.size, size >= 0 {
                fileSizes[item.path] = size
            }
        }
        var total: Int64 = 0
        for path in expectedPaths {
            guard let size = fileSizes[path] else {
                throw HuggingFaceHubError.invalidResponse
            }
            let (next, overflowed) = total.addingReportingOverflow(size)
            guard !overflowed else {
                throw HuggingFaceHubError.invalidResponse
            }
            total = next
        }
        return total
    }

    private static func searchTerm(_ query: String) -> String {
        guard let components = URLComponents(string: query),
              components.host?.lowercased() == "huggingface.co"
        else {
            return query
        }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2 else { return query }
        return parts.prefix(2).joined(separator: "/")
    }
}

enum HuggingFaceArtifactSizeState: Equatable {
    case idle
    case loading
    case available(Int64)
    case unavailable
}

@MainActor
final class HuggingFaceLoRAAdapterSizeStore: ObservableObject {
    static let shared = HuggingFaceLoRAAdapterSizeStore()

    @Published private var states: [
        HubLoRAAdapterReference: HuggingFaceArtifactSizeState
    ] = [:]

    private let client: HuggingFaceLoRAAdapterClient

    init(client: HuggingFaceLoRAAdapterClient = HuggingFaceLoRAAdapterClient()) {
        self.client = client
    }

    func state(
        for reference: HubLoRAAdapterReference
    ) -> HuggingFaceArtifactSizeState {
        states[reference] ?? .idle
    }

    func load(
        adapter: HuggingFaceLoRAAdapter,
        variant: LoRAAdapterArtifactVariant,
        token: String?
    ) async {
        let key = variant.reference
        switch state(for: key) {
        case .loading, .available:
            return
        case .idle, .unavailable:
            break
        }

        states[key] = .loading
        do {
            let size = try await client.artifactSize(
                adapter: adapter,
                variant: variant,
                token: token
            )
            try Task.checkCancellation()
            states[key] = .available(size)
        } catch is CancellationError {
            states[key] = .idle
        } catch {
            states[key] = .unavailable
        }
    }

}

@MainActor
final class HuggingFaceLoRAAdapterLibrary: ObservableObject {
    @Published private(set) var adapters: [HuggingFaceLoRAAdapter] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?

    private let client: HuggingFaceLoRAAdapterClient
    private var task: Task<Void, Never>?

    init(client: HuggingFaceLoRAAdapterClient = HuggingFaceLoRAAdapterClient()) {
        self.client = client
    }

    deinit { task?.cancel() }

    func search(baseModelID: String, query: String, token: String?) {
        task?.cancel()
        isSearching = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let adapters = try await client.search(
                    baseModelID: baseModelID,
                    query: query,
                    token: token
                )
                try Task.checkCancellation()
                self.adapters = adapters
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.adapters = []
                self.error = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.isSearching = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }
}

@MainActor
final class LoRAAdapterDownloadManager: ObservableObject {
    enum InstallPhase: Equatable {
        case preparing
        case downloading
        case retrying(attempt: Int, maximumAttempts: Int)
        case paused
        case verifying
        case installing

        var description: String {
            switch self {
            case .preparing:
                return "Preparing download…"
            case .downloading:
                return "Downloading…"
            case .retrying(let attempt, let maximumAttempts):
                return "Connection interrupted · retrying \(attempt) of \(maximumAttempts)…"
            case .paused:
                return "Download paused"
            case .verifying:
                return "Verifying adapter…"
            case .installing:
                return "Finishing installation…"
            }
        }

        var showsDeterminateProgress: Bool {
            switch self {
            case .downloading, .retrying, .paused:
                return true
            case .preparing, .verifying, .installing:
                return false
            }
        }
    }

    @Published private(set) var activeReferenceID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var phase: InstallPhase?
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var error: String?

    private var operation: HuggingFaceDownloadOperation?
    private var task: Task<URL, Error>?
    private var installID: UUID?

    var isDownloading: Bool { activeReferenceID != nil }

    func install(
        adapter: HuggingFaceLoRAAdapter,
        variant: LoRAAdapterArtifactVariant,
        baseModelID: String,
        token: String?,
        sizeBytes: Int64?,
        catalog: LoRAAdapterCatalog
    ) async throws -> InstalledLoRAAdapter {
        guard activeReferenceID == nil else {
            throw HuggingFaceHubError.anotherDownloadInProgress(
                activeReferenceID ?? adapter.id
            )
        }

        let installID = UUID()
        self.installID = installID
        activeReferenceID = variant.reference.id
        progress = 0
        phase = .preparing
        totalBytes = sizeBytes
        error = nil
        do {
            try FileManager.default.createDirectory(
                at: LoRAAdapterCache.defaultRootURL,
                withIntermediateDirectories: true
            )
            let operation = try HuggingFaceDownloadOperation(
                repoID: adapter.id,
                cachePath: LoRAAdapterCache.defaultRootURL.path,
                token: token,
                revision: variant.reference.revisionSHA,
                allowPatterns: [variant.configPath, variant.weightsPath],
                expectedBytes: sizeBytes,
                progressChunkBytes: 256 * 1_024,
                retry: { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.installID == installID else { return }
                        self.phase = .retrying(
                            attempt: event.attempt,
                            maximumAttempts: event.maximumAttempts
                        )
                    }
                }
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.installID == installID else { return }
                    self.progress = max(self.progress, progress)
                    if !self.isPaused {
                        self.phase = .downloading
                    }
                }
            }
            self.operation = operation

            let task = Task.detached(priority: .userInitiated) {
                try operation.run()
                guard let snapshotPath = operation.snapshotPath else {
                    throw HuggingFaceHubError.downloadFailed(
                        "The Hub downloader did not return a snapshot path."
                    )
                }
                var adapterURL = URL(fileURLWithPath: snapshotPath, isDirectory: true)
                if !variant.reference.subfolder.isEmpty {
                    adapterURL.appendPathComponent(
                        variant.reference.subfolder,
                        isDirectory: true
                    )
                }
                return adapterURL
            }
            self.task = task
            let adapterURL = try await task.value
            try ensureCurrentInstall(installID)
            phase = .verifying
            progress = 1

            let validation = try await Task.detached(priority: .userInitiated) {
                let summary = try LoRAAdapterPackageValidator.validate(at: adapterURL)
                try LoRAAdapterRuntimePackageValidator.validate(at: adapterURL)
                return summary
            }.value
            try Task.checkCancellation()
            try ensureCurrentInstall(installID)

            phase = .installing
            let installed = InstalledLoRAAdapter(
                reference: variant.reference,
                baseModelID: baseModelID,
                installedAt: Date(),
                sizeBytes: validation.sizeBytes,
                rank: validation.rank,
                tensorCount: validation.tensorCount
            )
            try catalog.install(installed)
            finish(ifCurrent: installID)
            return installed
        } catch is CancellationError {
            finish(ifCurrent: installID)
            throw CancellationError()
        } catch {
            guard self.installID == installID else {
                throw CancellationError()
            }
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            finish(ifCurrent: installID, preservingError: true)
            throw error
        }
    }

    func cancel() {
        operation?.cancel()
        task?.cancel()
        finish()
    }

    func pause() {
        guard activeReferenceID != nil, !isPaused else { return }
        operation?.pause()
        isPaused = true
        phase = .paused
    }

    func resume() {
        guard activeReferenceID != nil, isPaused else { return }
        operation?.resume()
        isPaused = false
        phase = .downloading
    }

    private func ensureCurrentInstall(_ expectedID: UUID) throws {
        guard installID == expectedID else {
            throw CancellationError()
        }
    }

    private func finish(
        ifCurrent expectedID: UUID? = nil,
        preservingError: Bool = false
    ) {
        if let expectedID, installID != expectedID {
            return
        }
        operation = nil
        task = nil
        installID = nil
        activeReferenceID = nil
        progress = 0
        isPaused = false
        phase = nil
        totalBytes = nil
        if !preservingError {
            error = nil
        }
    }
}
