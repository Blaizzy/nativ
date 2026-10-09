import Foundation
import ZIPFoundation

/// Installs the default speech model once, independently of the local model server.
actor ParakeetModelStore {
    static let shared = ParakeetModelStore()
    static let archiveURL = URL(string: "https://huggingface.co/nativ-community/parakeet-redux-coreai-fp16/resolve/main/parakeet-redux-coreai-fp16.zip?download=true")!
    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nativ/SpeechModels", isDirectory: true)

    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)
    private let root: URL
    private let source: URL
    private let download: Download
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let modelName = "parakeet-redux-coreai"
    private static let receiptName = "install-receipt.json"
    private static let requiredFiles = [
        "config.json", "vocabulary.json", "model.aimodel/main.mlirb",
        "model.aimodel/main.hash", "model.aimodel/metadata.json",
    ]

    private struct Receipt: Codable {
        let version: Int
        let source: URL
        let sizes: [String: Int]
    }

    init(root: URL = cacheDirectory, source: URL = archiveURL, download: @escaping Download = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 120
        return try await URLSession.shared.download(for: request)
    }) {
        self.root = root
        self.source = source
        self.download = download
    }

    func directory() async throws -> URL {
        // Serialize through extraction/publication as well as the network await.
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
        defer {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let destination = root.appendingPathComponent(Self.modelName, isDirectory: true)
        if isInstalled(at: destination) { return destination }

        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        NSLog("Nativ downloading Parakeet speech model")
        let (temporary, response) = try await download(source)
        defer { try? files.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ParakeetError.modelDownloadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try Task.checkCancellation()
        let archive = staging.appendingPathComponent("model.zip")
        try files.moveItem(at: temporary, to: archive)
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        try Self.extract(archive, to: expanded)
        let wrapped = expanded.appendingPathComponent(Self.modelName, isDirectory: true)
        let candidate = files.fileExists(atPath: wrapped.path) ? wrapped : expanded
        let sizes = try Self.validate(candidate)
        let receipt = Receipt(version: 1, source: source, sizes: sizes)
        try JSONEncoder().encode(receipt).write(to: candidate.appendingPathComponent(Self.receiptName), options: .atomic)
        try Task.checkCancellation()

        // Another app process may have completed the same installation meanwhile.
        if isInstalled(at: destination) { return destination }
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        do {
            // Same-filesystem rename: readers only see a complete installation.
            try files.moveItem(at: candidate, to: destination)
        } catch {
            guard isInstalled(at: destination) else { throw error }
        }
        NSLog("Nativ cached Parakeet speech model at %@", destination.path)
        return destination
    }

    private func isInstalled(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.receiptName)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.version == 1, receipt.source == source,
              let sizes = try? Self.validate(directory), sizes == receipt.sizes else { return false }
        return true
    }

    private static func validate(_ directory: URL) throws -> [String: Int] {
        var sizes = [String: Int]()
        for path in requiredFiles {
            let values = try directory.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else { throw ParakeetError.invalidBundle }
            sizes[path] = size
        }
        guard sizes["model.aimodel/main.hash"] == 32,
              sizes["config.json"]! <= 1_048_576, sizes["vocabulary.json"]! <= 16_777_216 else {
            throw ParakeetError.invalidBundle
        }
        let config = try ParakeetConfiguration.load(from: directory)
        let vocabulary = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
        guard vocabulary.count == config.metadata.blankId else { throw ParakeetError.invalidBundle }
        return sizes
    }

    private static func extract(_ url: URL, to destination: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var expandedBytes: UInt64 = 0
        let expandedLimit: UInt64 = 4 * 1_024 * 1_024 * 1_024
        // Inspect before writing. This model needs no symlinks or outside paths.
        for (index, entry) in archive.enumerated() {
            let components = entry.path.split(separator: "/")
            guard index < 10_000, !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !components.contains(".."), entry.type != .symlink,
                  entry.uncompressedSize <= expandedLimit - expandedBytes else {
                throw ParakeetError.invalidModelArchive
            }
            expandedBytes += entry.uncompressedSize
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in archive {
            try Task.checkCancellation()
            if entry.path.split(separator: "/").contains("__MACOSX") || entry.path.hasSuffix(".DS_Store") { continue }
            let target = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(destination.path + "/") else { throw ParakeetError.invalidModelArchive }
            let checksum = try archive.extract(entry, to: target)
            guard checksum == entry.checksum else { throw ParakeetError.invalidModelArchive }
        }
    }
}
