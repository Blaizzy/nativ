import Foundation
import UniformTypeIdentifiers

enum ChatAttachmentKind: Equatable, Sendable {
    case image
    case pdf
    case unsupported
}

extension ChatImageAttachment {
    var chatAttachmentKind: ChatAttachmentKind {
        let normalizedMIMEType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedMIMEType.isEmpty,
           normalizedMIMEType != "application/octet-stream" {
            return Self.kind(for: UTType(mimeType: normalizedMIMEType))
        }

        let fileExtension = (filename as NSString).pathExtension
        return Self.kind(for: UTType(filenameExtension: fileExtension))
    }

    private static func kind(for type: UTType?) -> ChatAttachmentKind {
        guard let type else {
            return .unsupported
        }
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .pdf) {
            return .pdf
        }
        return .unsupported
    }
}
