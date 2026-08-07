import Foundation
import NativServerKit

@MainActor
final class ArtifactSearchIndex: ObservableObject {
    @Published private(set) var indexedCount = 0
    @Published private(set) var isIndexing = false

    // Visual (image / video frame) and text (metadata / document body) component
    // vectors live in separate groups: they occupy different regions of the
    // embedding space and are matched against differently-phrased queries.
    struct StoredVectors: Codable {
        var visual: [[Float]] = []
        var text: [[Float]] = []
    }

    private var vectors: [UUID: StoredVectors] = [:]
    private let storageURL: URL

    private static let visualThreshold: Float = 0.35
    private static let textThreshold: Float = 0.50

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        storageURL = support
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Artifact Vectors.json")
        vectors = Self.load(storageURL)
        indexedCount = vectors.count
    }

    var hasIndex: Bool {
        !vectors.isEmpty
    }

    func index(
        artifacts: [Artifact],
        model: String,
        client: NativEmbeddingsClient,
        visualURLs: @escaping (Artifact) async -> [String],
        textChunks: @escaping (Artifact) async -> [String]
    ) async {
        guard !isIndexing else {
            return
        }
        isIndexing = true
        defer { isIndexing = false }

        let liveIDs = Set(artifacts.map(\.id))
        vectors = vectors.filter { liveIDs.contains($0.key) }

        for artifact in artifacts where vectors[artifact.id] == nil {
            if Task.isCancelled {
                break
            }
            if let stored = await Self.embed(
                artifact: artifact, model: model, client: client,
                visualURLs: visualURLs, textChunks: textChunks
            ) {
                vectors[artifact.id] = stored
                indexedCount = vectors.count
            }
        }
        Self.save(vectors, to: storageURL)
    }

    func search(query: String, model: String, client: NativEmbeddingsClient, limit: Int = 400) async -> [UUID]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vectors.isEmpty else {
            return nil
        }
        // Images need a caption-style prompt; text retrieval needs a query prompt.
        guard let visualVector = try? await client.embed(text: "a photo of \(trimmed)", model: model),
              let textVector = try? await client.embed(text: "Query: \(trimmed)", model: model) else {
            return nil
        }
        let queryVisual = Self.normalized(visualVector)
        let queryText = Self.normalized(textVector)

        let ranked = vectors
            .compactMap { id, stored -> (id: UUID, score: Float)? in
                let bestVisual = stored.visual.map { Self.dot(queryVisual, $0) }.max() ?? -1
                let bestText = stored.text.map { Self.dot(queryText, $0) }.max() ?? -1
                guard bestVisual > Self.visualThreshold || bestText > Self.textThreshold else {
                    return nil
                }
                return (id, max(bestVisual, bestText))
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
        return ranked.map(\.id)
    }

    func clear() {
        vectors = [:]
        indexedCount = 0
        try? FileManager.default.removeItem(at: storageURL)
    }

    // MARK: - Embedding

    private static func embed(
        artifact: Artifact,
        model: String,
        client: NativEmbeddingsClient,
        visualURLs: (Artifact) async -> [String],
        textChunks: (Artifact) async -> [String]
    ) async -> StoredVectors? {
        var stored = StoredVectors()

        for url in await visualURLs(artifact) {
            if let vector = try? await client.embed(dataURL: url, model: model) {
                stored.visual.append(normalized(vector))
            }
        }

        let metadata = [artifact.filename, artifact.sessionTitle, artifact.prompt ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        var texts = metadata.isEmpty ? [] : [metadata]
        texts.append(contentsOf: await textChunks(artifact))
        for text in texts {
            if let vector = try? await client.embed(text: text, model: model) {
                stored.text.append(normalized(vector))
            }
        }

        return (stored.visual.isEmpty && stored.text.isEmpty) ? nil : stored
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else {
            return vector
        }
        return vector.map { $0 / magnitude }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            return 0
        }
        var total: Float = 0
        for index in 0..<a.count {
            total += a[index] * b[index]
        }
        return total
    }

    // MARK: - Persistence

    private static func load(_ url: URL) -> [UUID: StoredVectors] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: StoredVectors].self, from: data)
        else {
            return [:]
        }
        var result: [UUID: StoredVectors] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) {
                result[id] = value
            }
        }
        return result
    }

    private static func save(_ vectors: [UUID: StoredVectors], to url: URL) {
        var raw: [String: StoredVectors] = [:]
        for (id, value) in vectors {
            raw[id.uuidString] = value
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(raw) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
