import AppKit
import Combine
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class ArtifactStore: ObservableObject {
    struct StorageLocations {
        let indexURL: URL
        let cacheDirectory: URL
        let favoritesURL: URL
        let displayNamesURL: URL

        static var application: Self {
            let fileManager = FileManager.default
            let support = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? fileManager.temporaryDirectory
            let nativDirectory = support.appendingPathComponent("Nativ", isDirectory: true)
            let caches = fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first ?? fileManager.temporaryDirectory

            return Self(
                indexURL: nativDirectory.appendingPathComponent("Artifacts Index.json"),
                cacheDirectory: caches
                    .appendingPathComponent("Nativ", isDirectory: true)
                    .appendingPathComponent("Artifacts", isDirectory: true),
                favoritesURL: nativDirectory.appendingPathComponent("Artifact Favorites.json"),
                displayNamesURL: nativDirectory.appendingPathComponent("Artifact Names.json")
            )
        }
    }

    struct CatalogSnapshot: Sendable {
        let fingerprint: String?
        let artifacts: [Artifact]
    }

    typealias Rebuild = @Sendable (URL, URL, CatalogSnapshot) -> CatalogSnapshot

    typealias DeletionHandler = (Artifact) -> Bool

    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isRefreshing = false

    @Published private(set) var favoriteIDs: Set<UUID> = []
    @Published private(set) var displayNames: [UUID: String] = [:]

    private var mutationRevision = 0
    private var knownFingerprint: String?
    private let mediaStore: MediaAssetStore
    private let rebuildIndex: Rebuild
    private var persistedDataChangeCancellable: AnyCancellable?
    private var refreshPending = false
    private let deletionHandler: DeletionHandler
    private let indexURL: URL
    private let cacheDirectory: URL
    private let favoritesURL: URL
    private let displayNamesURL: URL
    private let thumbnailCache = NSCache<NSString, NSImage>()

    init(
        storage: StorageLocations = .application,
        refreshesAutomatically: Bool = true,
        persistedDataChanges: PersistedDataChangeHub? = nil,
        rebuild: Rebuild? = nil,
        mediaStore: MediaAssetStore = .shared,
        deletionHandler: @escaping DeletionHandler = { _ in true }
    ) {
        self.mediaStore = mediaStore
        rebuildIndex = rebuild ?? Self.rebuild
        self.deletionHandler = deletionHandler
        indexURL = storage.indexURL
        cacheDirectory = storage.cacheDirectory
        favoritesURL = storage.favoritesURL
        displayNamesURL = storage.displayNamesURL

        thumbnailCache.countLimit = 150
        favoriteIDs = Self.loadFavorites(favoritesURL)
        displayNames = Self.loadNames(displayNamesURL)
        let stored = Self.loadIndex(indexURL)
        artifacts = stored.artifacts
        knownFingerprint = stored.fingerprint
        persistedDataChangeCancellable = persistedDataChanges?.changes
            .sink { [weak self] change in
                switch change.kind {
                case .chatSession, .imageGenerationSession:
                    self?.refresh()
                case .chatFolders:
                    break
                }
            }
        if refreshesAutomatically {
            refresh()
        }
    }

    func fileURL(for artifact: Artifact) -> URL {
        if let asset = artifact.asset, let url = mediaStore.fileURL(for: asset) { return url }
        return cacheDirectory.appendingPathComponent(artifact.relativePath)
    }

    // MARK: - Favorites & rename

    func isFavorite(_ artifact: Artifact) -> Bool {
        favoriteIDs.contains(artifact.id)
    }

    func toggleFavorite(_ artifact: Artifact) {
        if favoriteIDs.contains(artifact.id) {
            favoriteIDs.remove(artifact.id)
        } else {
            favoriteIDs.insert(artifact.id)
        }
        Self.saveFavorites(favoriteIDs, to: favoritesURL)
    }

    func displayName(for artifact: Artifact) -> String {
        let custom = displayNames[artifact.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return custom
        }
        return artifact.filename
    }

    func rename(_ artifact: Artifact, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == artifact.filename {
            displayNames[artifact.id] = nil
        } else {
            displayNames[artifact.id] = trimmed
        }
        Self.saveNames(displayNames, to: displayNamesURL)
    }

    func textPreview(for artifact: Artifact, lineLimit: Int = 12) async -> String? {
        let url = fileURL(for: artifact)
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            guard let text = String(data: data.prefix(8192), encoding: .utf8) else {
                return nil
            }
            let lines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(lineLimit)
            let joined = lines.joined(separator: "\n")
            return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
        }.value
    }

    private static func loadFavorites(_ url: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private static func saveFavorites(_ ids: Set<UUID>, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ids.map(\.uuidString)) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadNames(_ url: URL) -> [UUID: String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var result: [UUID: String] = [:]
        for (key, value) in raw where UUID(uuidString: key) != nil {
            result[UUID(uuidString: key)!] = value
        }
        return result
    }

    private static func saveNames(_ names: [UUID: String], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var raw: [String: String] = [:]
        for (id, value) in names {
            raw[id.uuidString] = value
        }
        guard let data = try? JSONEncoder().encode(raw) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    func refresh() {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        let cache = cacheDirectory
        let index = indexURL
        let known = CatalogSnapshot(fingerprint: knownFingerprint, artifacts: artifacts)
        let revision = mutationRevision
        let rebuild = rebuildIndex
        Task.detached(priority: .utility) {
            let rebuilt = rebuild(cache, index, known)
            await MainActor.run {
                if revision == self.mutationRevision {
                    self.artifacts = rebuilt.artifacts
                    self.knownFingerprint = rebuilt.fingerprint
                } else {
                    self.refreshPending = true
                }
                self.isRefreshing = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    @discardableResult
    func delete(_ artifact: Artifact) -> Bool {
        guard deletionHandler(artifact) else {
            return false
        }
        mutationRevision += 1
        knownFingerprint = nil
        if artifact.asset == nil {
            try? FileManager.default.removeItem(at: fileURL(for: artifact))
        }
        artifacts.removeAll { $0.id == artifact.id }
        Self.writeIndex(artifacts, fingerprint: nil, to: indexURL)
        return true
    }

    @discardableResult
    func delete(_ toDelete: [Artifact]) -> Set<Artifact.ID> {
        var deletedIDs: Set<Artifact.ID> = []
        for artifact in toDelete {
            guard !deletedIDs.contains(artifact.id), deletionHandler(artifact) else {
                continue
            }
            mutationRevision += 1
            if artifact.asset == nil {
                try? FileManager.default.removeItem(at: fileURL(for: artifact))
            }
            deletedIDs.insert(artifact.id)
        }
        if !deletedIDs.isEmpty {
            knownFingerprint = nil
        }
        artifacts.removeAll { deletedIDs.contains($0.id) }
        Self.writeIndex(artifacts, fingerprint: nil, to: indexURL)
        return deletedIDs
    }

    func revealInFinder(_ artifact: Artifact) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: artifact)])
    }

    func open(_ artifact: Artifact) {
        NSWorkspace.shared.open(fileURL(for: artifact))
    }

    func export(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fileURL(for: artifact), to: destination)
    }

    func exportToDirectory(_ toExport: [Artifact]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }
        for artifact in toExport {
            let destination = directory.appendingPathComponent(artifact.filename)
            try? FileManager.default.copyItem(at: fileURL(for: artifact), to: destination)
        }
    }

    func copyToPasteboard(_ artifact: Artifact) {
        let url = fileURL(for: artifact)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [NSPasteboardWriting] = [url as NSURL]
        if artifact.kind == .image, let image = NSImage(contentsOf: url) {
            items.append(image)
        }
        pasteboard.writeObjects(items)
    }

    func dragProvider(for artifact: Artifact) -> NSItemProvider {
        NSItemProvider(contentsOf: fileURL(for: artifact)) ?? NSItemProvider()
    }

    func chatAttachment(for artifact: Artifact) -> ChatImageAttachment? {
        guard let asset = artifact.asset, mediaStore.fileURL(for: asset) != nil else { return nil }
        var attachment = ChatImageAttachment(
            id: artifact.id, filename: artifact.filename, mimeType: artifact.mimeType, asset: asset
        )
        attachment.generation = artifact.generation
        attachment.origin = artifact.source
        return attachment
    }

    func thumbnail(for artifact: Artifact, size: CGSize) async -> NSImage? {
        let key = "\(artifact.id.uuidString)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        let url = fileURL(for: artifact)
        let image = artifact.kind == .image
            ? await Self.downsampledImage(url, size: size)
            : await Self.generateThumbnail(url, size: size)
        if let image {
            thumbnailCache.setObject(image, forKey: key)
        }
        return image
    }

    // MARK: - Scanning

    nonisolated static func legacyCacheMarkerURL(indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent()
            .appendingPathComponent("Artifacts Legacy Cache Removed.txt")
    }

    @discardableResult
    nonisolated static func removeLegacyCache(cacheDirectory: URL, indexURL: URL) -> Bool {
        let fileManager = FileManager.default
        let marker = legacyCacheMarkerURL(indexURL: indexURL)
        guard !fileManager.fileExists(atPath: marker.path) else { return false }

        try? fileManager.removeItem(at: cacheDirectory)
        guard !fileManager.fileExists(atPath: cacheDirectory.path) else { return false }

        try? fileManager.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? "unified-v2".write(to: marker, atomically: true, encoding: .utf8)
        return true
    }

    private nonisolated static func rebuild(
        cacheDirectory: URL, indexURL: URL, known: CatalogSnapshot
    ) -> CatalogSnapshot {
        let chats = ChatSessionStore()
        let images = ImageGenerationSessionStore()
        let fingerprint = "unified-v2#" + chats.sessionsFingerprint() + "#" + images.fingerprint()
        if !known.artifacts.isEmpty,
           known.fingerprint == fingerprint,
           known.artifacts.allSatisfy({ artifact in
               artifact.asset.flatMap(MediaAssetStore.shared.fileURL) != nil
           }) {
            return known
        }

        let artifacts = ArtifactCatalog.artifacts(chats: chats.loadSessions(), images: images.loadSessions())
            .filter { $0.asset.flatMap(MediaAssetStore.shared.fileURL) != nil }
        writeIndex(artifacts, fingerprint: fingerprint, to: indexURL)
        removeLegacyCache(cacheDirectory: cacheDirectory, indexURL: indexURL)
        return CatalogSnapshot(fingerprint: fingerprint, artifacts: artifacts)
    }

    // MARK: - Thumbnails

    private nonisolated static func downsampledImage(_ url: URL, size: CGSize) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let maxPixel = Int(max(size.width, size.height) * scale)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }

    private nonisolated static func generateThumbnail(_ url: URL, size: CGSize) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard let representation else {
            return nil
        }
        return NSImage(cgImage: representation.cgImage, size: size)
    }

    // MARK: - Index

    private struct StoredIndex: Codable {
        let fingerprint: String?
        let artifacts: [Artifact]
    }

    nonisolated static func loadIndex(_ url: URL) -> CatalogSnapshot {
        guard let data = try? Data(contentsOf: url) else {
            return CatalogSnapshot(fingerprint: nil, artifacts: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stored = try? decoder.decode(StoredIndex.self, from: data) {
            return CatalogSnapshot(fingerprint: stored.fingerprint, artifacts: stored.artifacts)
        }
        let legacy = (try? decoder.decode([Artifact].self, from: data)) ?? []
        return CatalogSnapshot(fingerprint: nil, artifacts: legacy)
    }

    nonisolated static func writeIndex(
        _ artifacts: [Artifact], fingerprint: String?, to url: URL
    ) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = StoredIndex(fingerprint: fingerprint, artifacts: artifacts)
        guard let data = try? encoder.encode(stored) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
