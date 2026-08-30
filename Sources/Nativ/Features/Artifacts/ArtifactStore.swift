import AppKit
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

    typealias DeletionHandler = (Artifact) -> Bool

    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isRefreshing = false

    @Published private(set) var favoriteIDs: Set<UUID> = []
    @Published private(set) var displayNames: [UUID: String] = [:]

    private let deletionHandler: DeletionHandler
    private let indexURL: URL
    private let cacheDirectory: URL
    private let favoritesURL: URL
    private let displayNamesURL: URL
    private let thumbnailCache = NSCache<NSString, NSImage>()

    init(
        storage: StorageLocations = .application,
        refreshesAutomatically: Bool = true,
        deletionHandler: @escaping DeletionHandler = { _ in true }
    ) {
        self.deletionHandler = deletionHandler
        indexURL = storage.indexURL
        cacheDirectory = storage.cacheDirectory
        favoritesURL = storage.favoritesURL
        displayNamesURL = storage.displayNamesURL

        thumbnailCache.countLimit = 150
        favoriteIDs = Self.loadFavorites(favoritesURL)
        displayNames = Self.loadNames(displayNamesURL)
        artifacts = Self.loadIndex(indexURL)
        if refreshesAutomatically {
            refresh()
        }
    }

    func fileURL(for artifact: Artifact) -> URL {
        cacheDirectory.appendingPathComponent(artifact.relativePath)
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
            return
        }
        isRefreshing = true
        let cache = cacheDirectory
        let index = indexURL
        let known = artifacts
        Task.detached(priority: .utility) {
            let rebuilt = Self.rebuild(cacheDirectory: cache, indexURL: index, known: known)
            await MainActor.run {
                self.artifacts = rebuilt
                self.isRefreshing = false
            }
        }
    }

    @discardableResult
    func delete(_ artifact: Artifact) -> Bool {
        guard deletionHandler(artifact) else {
            return false
        }
        try? FileManager.default.removeItem(at: fileURL(for: artifact))
        artifacts.removeAll { $0.id == artifact.id }
        Self.writeIndex(artifacts, to: indexURL)
        return true
    }

    @discardableResult
    func delete(_ toDelete: [Artifact]) -> Set<Artifact.ID> {
        var deletedIDs: Set<Artifact.ID> = []
        for artifact in toDelete {
            guard !deletedIDs.contains(artifact.id), deletionHandler(artifact) else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL(for: artifact))
            deletedIDs.insert(artifact.id)
        }
        artifacts.removeAll { deletedIDs.contains($0.id) }
        Self.writeIndex(artifacts, to: indexURL)
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
        try? ChatImageAttachment(contentsOf: fileURL(for: artifact))
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

    private nonisolated static func fingerprintURL(indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent().appendingPathComponent("Artifacts Fingerprint.txt")
    }

    private nonisolated static func rebuild(cacheDirectory: URL, indexURL: URL, known: [Artifact]) -> [Artifact] {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let fingerprint = ChatSessionStore().sessionsFingerprint()
            + "#" + ImageGenerationArtifactCatalog.fingerprint()
        let fingerprintFile = fingerprintURL(indexURL: indexURL)
        if !known.isEmpty,
           let previous = try? String(contentsOf: fingerprintFile, encoding: .utf8),
           previous == fingerprint,
           FileManager.default.fileExists(
               atPath: cacheDirectory.appendingPathComponent(known[0].relativePath).path
           ) {
            return known
        }

        var byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Artifact] = []

        for session in ChatSessionStore().loadSessions() {
            for message in session.messages {
                for attachment in message.imageAttachments {
                    if let artifact = materialize(
                        attachment,
                        source: .uploaded,
                        prompt: message.content.isEmpty ? nil : message.content,
                        session: session,
                        message: message,
                        cacheDirectory: cacheDirectory,
                        existing: byID[attachment.id]
                    ) {
                        result.append(artifact)
                        byID[artifact.id] = artifact
                    }
                }
            }
        }

        for record in ImageGenerationArtifactCatalog.generatedRecords() {
            if let artifact = materializeGenerated(
                record,
                cacheDirectory: cacheDirectory,
                existing: byID[record.id]
            ) {
                result.append(artifact)
                byID[artifact.id] = artifact
            }
        }

        let sorted = result.sorted { $0.createdAt > $1.createdAt }
        writeIndex(sorted, to: indexURL)
        pruneOrphans(cacheDirectory: cacheDirectory, keep: Set(sorted.map(\.relativePath)))
        try? fingerprint.write(to: fingerprintFile, atomically: true, encoding: .utf8)
        return sorted
    }

    private nonisolated static func pruneOrphans(cacheDirectory: URL, keep: Set<String>) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }
        let base = cacheDirectory.path.hasSuffix("/") ? cacheDirectory.path : cacheDirectory.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let relative = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
            if !keep.contains(relative) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private nonisolated static func materialize(
        _ attachment: ChatImageAttachment,
        source: ArtifactSource,
        prompt: String?,
        session: ChatSession,
        message: ChatTranscriptMessage,
        cacheDirectory: URL,
        existing: Artifact?
    ) -> Artifact? {
        let kind = ArtifactKind.resolve(mimeType: attachment.mimeType, filename: attachment.filename)
        let relativePath = "\(kind.rawValue)/\(attachment.id.uuidString).\(fileExtension(for: attachment))"
        let destination = cacheDirectory.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if let existing, fileManager.fileExists(atPath: destination.path) {
            return existing
        }

        guard let data = Data(base64Encoded: attachment.base64Data) else {
            return nil
        }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? data.write(to: destination, options: .atomic)) != nil else {
            return nil
        }

        return Artifact(
            id: attachment.id,
            kind: kind,
            source: source,
            sessionID: session.id,
            messageID: message.id,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            relativePath: relativePath,
            byteSize: data.count,
            createdAt: message.createdAt,
            prompt: prompt,
            sessionTitle: session.displayTitle
        )
    }

    private nonisolated static func materializeGenerated(
        _ record: GeneratedArtifactRecord,
        cacheDirectory: URL,
        existing: Artifact?
    ) -> Artifact? {
        let ext = UTType(mimeType: record.mimeType)?.preferredFilenameExtension ?? "png"
        let filename = "image-\(record.id.uuidString.prefix(8)).\(ext)"
        let kind = ArtifactKind.resolve(mimeType: record.mimeType, filename: filename)
        let relativePath = "\(kind.rawValue)/\(record.id.uuidString).\(ext)"
        let destination = cacheDirectory.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if let existing, fileManager.fileExists(atPath: destination.path) {
            return existing
        }

        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? record.imageData.write(to: destination, options: .atomic)) != nil else {
            return nil
        }

        return Artifact(
            id: record.id,
            kind: kind,
            source: .generated,
            sessionID: record.sessionID,
            messageID: record.turnID,
            filename: filename,
            mimeType: record.mimeType,
            relativePath: relativePath,
            byteSize: record.imageData.count,
            createdAt: record.createdAt,
            prompt: record.prompt,
            sessionTitle: record.sessionTitle
        )
    }

    private nonisolated static func fileExtension(for attachment: ChatImageAttachment) -> String {
        if let ext = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension {
            return ext
        }
        let ext = (attachment.filename as NSString).pathExtension
        return ext.isEmpty ? "dat" : ext
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

    private nonisolated static func loadIndex(_ url: URL) -> [Artifact] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Artifact].self, from: data)) ?? []
    }

    private nonisolated static func writeIndex(_ artifacts: [Artifact], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(artifacts) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
