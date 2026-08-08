import AppKit
import Combine
import Foundation
import NativServerKit
import UniformTypeIdentifiers

enum SessionModelKind: String, Codable, Equatable, Sendable {
    case language
    case imageGeneration
}

struct ImageRequestSettings: Equatable, Codable, Sendable {
    var count = 1
    var width = 512
    var height = 512
    var steps = 4
    var guidance = 1.0
    var seedText = ""
}

struct ImageGenerationExecutor {
    func run(
        baseURL: URL,
        apiKey: String?,
        modelID: String,
        prompt: String,
        references: [ChatImageAttachment],
        settings: ImageRequestSettings,
        seed: Int?
    ) async throws -> [GeneratedImage] {
        let client = NativImageClient(baseURL: baseURL, apiKey: apiKey)
        let response: MLXImageResponse
        if references.isEmpty {
            response = try await client.generate(MLXImageGenerationRequest(
                model: modelID,
                prompt: prompt,
                n: settings.count,
                width: settings.width,
                height: settings.height,
                steps: settings.steps,
                seed: seed,
                guidance: settings.guidance
            ))
        } else {
            let paths = try references.map(Self.materializeReference).map(\.path)
            response = try await client.edit(MLXImageEditRequest(
                model: modelID,
                prompt: prompt,
                image: paths,
                n: settings.count,
                width: settings.width,
                height: settings.height,
                steps: settings.steps,
                seed: seed,
                guidance: settings.guidance
            ))
        }

        try Task.checkCancellation()
        return try Self.makeGeneratedImages(from: response)
    }

    private static func materializeReference(_ attachment: ChatImageAttachment) throws -> URL {
        guard let data = attachment.imageData else {
            throw NativImageError.missingImageData
        }
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = caches
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("ImageGeneration", isDirectory: true)
            .appendingPathComponent("References", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileExtension = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension
            ?? URL(fileURLWithPath: attachment.filename).pathExtension.nonEmpty
            ?? "png"
        let url = directory.appendingPathComponent("\(attachment.id.uuidString).\(fileExtension)")
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    private static func makeGeneratedImages(from response: MLXImageResponse) throws -> [GeneratedImage] {
        let images = response.data.compactMap { item -> GeneratedImage? in
            let data: Data?
            if let base64 = item.b64JSON {
                data = Data(base64Encoded: base64)
            } else if let path = item.path {
                data = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                data = nil
            }
            guard let data, NSImage(data: data) != nil else {
                return nil
            }
            return GeneratedImage(
                imageData: data,
                mimeType: item.mimeType,
                width: item.width,
                height: item.height,
                seed: item.seed,
                path: item.path,
                revisedPrompt: item.revisedPrompt
            )
        }
        guard !images.isEmpty else {
            throw NativImageError.missingImageData
        }
        return images
    }
}

enum ImageGenerationTurnStatus: String, Equatable, Codable, Sendable {
    case inProgress
    case completed
    case failed
    case cancelled
}

struct ImageGenerationTurn: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let prompt: String
    let referenceImages: [ChatImageAttachment]
    let modelID: String
    let settings: ImageRequestSettings
    let createdAt: Date
    var outputs: [GeneratedImage]
    var status: ImageGenerationTurnStatus
    var errorMessage: String?
}

private struct ImageGenerationSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelKind: SessionModelKind
    var modelID: String
    var draftSettings: ImageRequestSettings
    var activeReference: ChatImageAttachment?
    var turns: [ImageGenerationTurn]

    var displayTitle: String {
        Self.defaultTitle(turns: turns, createdAt: createdAt, fallback: title)
    }

    static func recencySort(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.createdAt > rhs.createdAt : lhs.updatedAt > rhs.updatedAt
    }

    static func timestampTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func defaultTitle(
        turns: [ImageGenerationTurn],
        createdAt: Date,
        fallback: String? = nil
    ) -> String {
        if let firstPrompt = turns.first?.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstPrompt.isEmpty {
            return firstPrompt.count > 56 ? "\(firstPrompt.prefix(53))…" : firstPrompt
        }
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedFallback.isEmpty ? timestampTitle(for: createdAt) : trimmedFallback
    }
}

private struct ImageGenerationSessionStore {
    private let fileManager = FileManager.default

    func loadSessions() -> [ImageGenerationSession] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(loadSession)
            .sorted(by: ImageGenerationSession.recencySort)
    }

    func loadSession(id: UUID) -> ImageGenerationSession? {
        loadSession(from: sessionURL(for: id))
    }

    func fingerprint() -> String {
        let urls = (try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values?.fileSize ?? 0
                return "\(url.lastPathComponent):\(mtime):\(size)"
            }
            .sorted()
            .joined(separator: "|")
    }

    func saveSession(_ session: ImageGenerationSession) {
        do {
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: sessionURL(for: session.id), options: .atomic)
        } catch {
            // Persistence should never prevent local image generation.
        }
    }

    func deleteSession(id: UUID) {
        try? fileManager.removeItem(at: sessionURL(for: id))
    }

    private func loadSession(from url: URL) -> ImageGenerationSession? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImageGenerationSession.self, from: data)
    }

    func sessionURL(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private var sessionsDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("ImageGeneration", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}

struct ImageGenerationPixelSize: Equatable, Codable, Sendable {
    let width: Int
    let height: Int
}

struct GeneratedImage: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let imageData: Data
    let mimeType: String
    let width: Int
    let height: Int
    let seed: Int
    let path: String?
    let revisedPrompt: String?

    init(
        id: UUID = UUID(),
        imageData: Data,
        mimeType: String,
        width: Int,
        height: Int,
        seed: Int,
        path: String?,
        revisedPrompt: String?
    ) {
        self.id = id
        self.imageData = imageData
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.seed = seed
        self.path = path
        self.revisedPrompt = revisedPrompt
    }

    var imageType: UTType {
        UTType(mimeType: mimeType) ?? .png
    }

    var filename: String {
        "image-\(seed).\(imageType.preferredFilenameExtension ?? "png")"
    }

    var attachment: ChatImageAttachment {
        ChatImageAttachment(
            id: id,
            filename: filename,
            mimeType: mimeType,
            base64Data: imageData.base64EncodedString()
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

struct GeneratedArtifactRecord: Sendable {
    let id: UUID
    let sessionID: UUID
    let turnID: UUID
    let prompt: String?
    let imageData: Data
    let mimeType: String
    let createdAt: Date
    let sessionTitle: String
}

enum ImageGenerationArtifactCatalog {
    static func fingerprint() -> String {
        ImageGenerationSessionStore().fingerprint()
    }

    static func generatedRecords() -> [GeneratedArtifactRecord] {
        ImageGenerationSessionStore().loadSessions().flatMap { session in
            session.turns.flatMap { turn in
                turn.outputs.map { output in
                    GeneratedArtifactRecord(
                        id: output.id,
                        sessionID: session.id,
                        turnID: turn.id,
                        prompt: output.revisedPrompt ?? (turn.prompt.isEmpty ? nil : turn.prompt),
                        imageData: output.imageData,
                        mimeType: output.mimeType,
                        createdAt: turn.createdAt,
                        sessionTitle: session.displayTitle
                    )
                }
            }
        }
    }

    static func removeOutput(sessionID: UUID, turnID: UUID, outputID: UUID) {
        let store = ImageGenerationSessionStore()
        guard var session = store.loadSession(id: sessionID) else {
            return
        }
        for index in session.turns.indices where session.turns[index].id == turnID {
            session.turns[index].outputs.removeAll { $0.id == outputID }
        }
        store.saveSession(session)
    }
}
