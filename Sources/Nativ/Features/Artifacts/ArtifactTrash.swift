import Combine
import CryptoKit
import Foundation

@MainActor
final class ArtifactTrash: ObservableObject {
    enum RecoveryError: LocalizedError {
        case busy, missing, saveFailed, conflict

        var errorDescription: String? {
            switch self {
            case .busy: "A linked session is generating a response. Try again when it finishes."
            case .missing: "The file is no longer available. It may have been removed from the Bin."
            case .saveFailed: "The history or recovery record could not be saved. Please try again."
            case .conflict: "Another file exists at the original location. Nothing was overwritten."
            }
        }
    }

    @Published private(set) var records: [ArtifactRecovery] = []
    @Published var errorMessage: String?
    private let directory: URL
    private let media: MediaAssetStore
    private let chats: ChatSessionStore
    private let images: ImageGenerationSessionStore
    private let isActive: (ArtifactUsage.Workspace, UUID) -> Bool
    private let didChange: (ArtifactUsage.Workspace, UUID) -> Void
    private let trashFile: (URL) throws -> URL

    init(
        directory: URL? = nil,
        media: MediaAssetStore = .shared,
        chats: ChatSessionStore = .init(),
        images: ImageGenerationSessionStore = .init(),
        isActive: @escaping (ArtifactUsage.Workspace, UUID) -> Bool = { _, _ in false },
        didChange: @escaping (ArtifactUsage.Workspace, UUID) -> Void = { _, _ in },
        trashFile: @escaping (URL) throws -> URL = ArtifactTrash.moveToBin
    ) {
        self.directory = directory ?? media.rootDirectory.deletingLastPathComponent().appendingPathComponent("Deleted Artifacts")
        self.media = media
        self.chats = chats
        self.images = images
        self.isActive = isActive
        self.didChange = didChange
        self.trashFile = trashFile
        do {
            if FileManager.default.fileExists(atPath: self.directory.path) {
                for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                    where url.pathExtension == "json" {
                    records.append(try JSONDecoder().decode(ArtifactRecovery.self, from: Data(contentsOf: url)))
                }
                records.sort { $0.deletedAt > $1.deletedAt }
            }
        } catch {
            errorMessage = "Some recovery records could not be read: \(error.localizedDescription)"
        }
    }

    func delete(_ artifact: Artifact) throws {
        guard !records.contains(where: { $0.id == artifact.id }),
              let asset = artifact.asset, let url = media.fileURL(for: asset) else { throw RecoveryError.missing }
        // Refresh locations before deletion: another window may have reused the file.
        let chatSessions = chats.loadSessions()
        let imageSessions = images.loadSessions()
        guard let current = ArtifactCatalog.artifacts(chats: chatSessions, images: imageSessions)
            .first(where: { $0.id == artifact.id }) else { throw RecoveryError.missing }
        try checkActivity(current.locations)
        var record = ArtifactRecovery(artifact: current, originalURL: url, chats: chatSessions, images: imageSessions)
        record.contentHash = try Self.contentHash(url)
        try save(record)
        media.updateOwner("trash:\(record.id)", assets: [asset])
        do {
            record.trashURL = try trashFile(url)
            try save(record)
            let removed = ArtifactDeletion.removeReferences(to: current, isActive: isActive) { workspace, id in
                switch workspace {
                case .chat:
                    guard var session = chatSessions.first(where: { $0.id == id }) else { return false }
                    session.removeArtifact(artifact.id)
                    guard chats.saveSession(session) else { return false }
                case .imageGeneration:
                    guard var session = imageSessions.first(where: { $0.id == id }) else { return false }
                    session.removeArtifact(artifact.id)
                    guard images.saveSession(session) else { return false }
                }
                didChange(workspace, id)
                return true
            }
            guard removed else { throw RecoveryError.saveFailed }
        } catch {
            // Keep the record if rollback also fails; recovery remains retryable.
            try? restore(record)
            throw error
        }
    }

    func restore(_ record: ArtifactRecovery) throws {
        try checkActivity(record.references.map(\.usage))
        let manager = FileManager.default
        if !manager.fileExists(atPath: record.originalURL.path) {
            guard let trashURL = record.trashURL, manager.fileExists(atPath: trashURL.path) else { throw RecoveryError.missing }
            guard try Self.contentHash(trashURL) == record.contentHash else { throw RecoveryError.conflict }
            try manager.createDirectory(at: record.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: trashURL, to: record.originalURL)
        } else {
            guard try Self.contentHash(record.originalURL) == record.contentHash else { throw RecoveryError.conflict }
            if let trashURL = record.trashURL, manager.fileExists(atPath: trashURL.path) {
                throw RecoveryError.conflict
            }
        }
        var restored = 0
        for id in Set(record.references.filter { $0.usage.workspace == .chat }.map { $0.usage.sessionID }) {
            guard var session = chats.loadSession(id: id) else { continue }
            restored += record.restore(into: &session)
            guard chats.saveSession(session) else { throw RecoveryError.saveFailed }
            didChange(.chat, id)
        }
        for id in Set(record.references.filter { $0.usage.workspace == .imageGeneration }.map { $0.usage.sessionID }) {
            guard var session = images.loadSession(id: id) else { continue }
            restored += record.restore(into: &session)
            guard images.saveSession(session) else { throw RecoveryError.saveFailed }
            didChange(.imageGeneration, id)
        }
        if restored == 0 {
            // Keep the file discoverable when its original chat or message was deleted.
            guard let asset = record.artifact.asset else { throw RecoveryError.missing }
            var attachment = ChatImageAttachment(id: record.id, filename: record.artifact.filename,
                                                 mimeType: record.artifact.mimeType, asset: asset, origin: record.artifact.source)
            attachment.generation = record.artifact.generation
            let session = ChatSession(id: record.recoveredChatID, title: "Recovered artifacts", customTitle: "Recovered artifacts",
                                      createdAt: .now, updatedAt: .now,
                                      messages: [ChatTranscriptMessage(role: .user, content: "", imageAttachments: [attachment])])
            // Retries must not replace a recovered chat that the user has since edited.
            if chats.loadSession(id: session.id) == nil {
                guard chats.saveSession(session) else { throw RecoveryError.saveFailed }
                didChange(.chat, session.id)
            }
        }
        try manager.removeItem(at: recordURL(record.id))
        records.removeAll { $0.id == record.id }
        media.updateOwner("trash:\(record.id)", assets: [])
    }

    private func checkActivity(_ locations: [ArtifactUsage]) throws {
        guard !locations.contains(where: { isActive($0.workspace, $0.sessionID) }) else { throw RecoveryError.busy }
    }

    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).json") }

    private func save(_ record: ArtifactRecovery) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL(record.id), options: .atomic)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
    }

    private static func contentHash(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return Data(hash.finalize())
    }

    nonisolated private static func moveToBin(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw RecoveryError.missing }
        return result as URL
    }
}
