import Foundation
import Observation

enum NativKitLibraryError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidIdentifier
    case invalidName
    case emptyKit
    case bundledKitCannotBeChanged
    case unresolvedLoadError

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This Kits file uses unsupported format version \(version)."
        case .invalidIdentifier:
            "The Kit has an invalid identifier."
        case .invalidName:
            "Enter a name for this Kit."
        case .emptyKit:
            "Select at least one capability for this Kit."
        case .bundledKitCannotBeChanged:
            "Built-in Kits cannot be edited or deleted."
        case .unresolvedLoadError:
            "Custom Kits can’t be changed until their saved file loads successfully."
        }
    }
}

@MainActor
@Observable
final class NativKitLibrary {
    private struct Payload: Codable {
        static let currentVersion = 1

        let version: Int
        let kits: [NativKit]

        private enum CodingKeys: String, CodingKey {
            case version
            case kits
        }

        init(kits: [NativKit]) {
            version = Self.currentVersion
            self.kits = kits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == Self.currentVersion else {
                throw NativKitLibraryError.unsupportedVersion(version)
            }
            kits = try container.decode([NativKit].self, forKey: .kits)
        }
    }

    private(set) var userKits: [NativKit] = []
    private(set) var lastErrorMessage: String?
    private var permitsWrites = true

    private let storageURL: URL
    private let fileManager: FileManager

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        reload()
    }

    var catalog: NativKitCatalog {
        do {
            return try NativKitCatalog.bundled.merging(userKits: userKits)
        } catch {
            assertionFailure("Invalid in-memory Kit catalog: \(error)")
            return .bundled
        }
    }

    func reload() {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            userKits = []
            lastErrorMessage = nil
            permitsWrites = true
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let kits = try payload.kits.map(normalized)
            _ = try NativKitCatalog.bundled.merging(userKits: kits)
            userKits = kits
            lastErrorMessage = nil
            permitsWrites = true
        } catch {
            lastErrorMessage = "Couldn’t load custom Kits: \(error.localizedDescription)"
            permitsWrites = false
        }
    }

    func upsert(_ kit: NativKit) throws {
        guard permitsWrites else { throw NativKitLibraryError.unresolvedLoadError }
        let kit = try normalized(kit)
        guard !NativKitCatalog.bundled.isBundled(kitID: kit.id) else {
            throw NativKitLibraryError.bundledKitCannotBeChanged
        }

        var candidate = userKits
        if let index = candidate.firstIndex(where: { $0.id == kit.id }) {
            candidate[index] = kit
        } else {
            candidate.append(kit)
        }
        _ = try NativKitCatalog.bundled.merging(userKits: candidate)
        try persist(candidate)
        userKits = candidate
        lastErrorMessage = nil
    }

    func delete(kitID: String) throws {
        guard permitsWrites else { throw NativKitLibraryError.unresolvedLoadError }
        guard !NativKitCatalog.bundled.isBundled(kitID: kitID) else {
            throw NativKitLibraryError.bundledKitCannotBeChanged
        }
        let candidate = userKits.filter { $0.id != kitID }
        guard candidate.count != userKits.count else { return }
        try persist(candidate)
        userKits = candidate
        lastErrorMessage = nil
    }

    private func normalized(_ kit: NativKit) throws -> NativKit {
        let identifier = kit.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw NativKitLibraryError.invalidIdentifier }
        let name = kit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NativKitLibraryError.invalidName }
        guard !kit.components.isEmpty else { throw NativKitLibraryError.emptyKit }

        var normalized = kit
        normalized.name = name
        normalized.summary = kit.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private func persist(_ kits: [NativKit]) throws {
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(kits: kits))
        try data.write(to: storageURL, options: .atomic)
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Kits.json")
    }
}
