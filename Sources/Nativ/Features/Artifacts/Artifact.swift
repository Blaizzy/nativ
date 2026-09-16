import Foundation
import UniformTypeIdentifiers

enum ArtifactKind: String, CaseIterable, Codable, Identifiable {
    case image
    case video
    case document

    var id: String { rawValue }

    var label: String {
        switch self {
        case .image:
            "Image"
        case .video:
            "Video"
        case .document:
            "Document"
        }
    }

    var pluralLabel: String {
        switch self {
        case .image:
            "Images"
        case .video:
            "Videos"
        case .document:
            "Documents"
        }
    }

    var systemImage: String {
        switch self {
        case .image:
            "photo"
        case .video:
            "film"
        case .document:
            "doc.text"
        }
    }

    static func resolve(mimeType: String, filename: String) -> ArtifactKind {
        let type = UTType(mimeType: mimeType)
            ?? UTType(filenameExtension: (filename as NSString).pathExtension)

        guard let type else {
            return .document
        }

        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        return .document
    }
}

enum ArtifactSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case uploaded
    case generated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uploaded:
            "Uploaded"
        case .generated:
            "Generated"
        }
    }

    var systemImage: String {
        switch self {
        case .uploaded:
            "square.and.arrow.up"
        case .generated:
            "sparkles"
        }
    }
}

struct ArtifactGeneration: Codable, Equatable, Sendable {
    var prompt: String?
    var modelID: String?
    var seed: Int?
    var width: Int?
    var height: Int?
}

struct ArtifactUsage: Codable, Equatable, Hashable, Sendable {
    enum Workspace: String, Codable, Sendable {
        case chat
        case imageGeneration
    }

    let workspace: Workspace
    let sessionID: UUID
    let messageID: UUID?
    let attachmentID: UUID
    var isGenerationOutput: Bool = false
}

struct Artifact: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: ArtifactKind
    let source: ArtifactSource
    let sessionID: UUID
    let messageID: UUID
    let filename: String
    let mimeType: String
    let relativePath: String
    let byteSize: Int
    let createdAt: Date
    let prompt: String?
    let sessionTitle: String
    var asset: MediaAssetReference? = nil
    var generation: ArtifactGeneration? = nil
    var usages: [ArtifactUsage]? = nil

    var locations: [ArtifactUsage] {
        usages ?? [ArtifactUsage(
            workspace: source == .generated ? .imageGeneration : .chat,
            sessionID: sessionID, messageID: messageID, attachmentID: id
        )]
    }

    var workspace: ArtifactUsage.Workspace {
        locations.first?.workspace ?? .chat
    }

    var fileExtension: String {
        (filename as NSString).pathExtension.uppercased()
    }

    var typeLabel: String {
        if let type = UTType(mimeType: mimeType), let description = type.localizedDescription {
            return description
        }
        return fileExtension.isEmpty ? kind.label : fileExtension
    }

    var searchText: String {
        [filename, prompt ?? "", typeLabel].joined(separator: " ").lowercased()
    }
}
