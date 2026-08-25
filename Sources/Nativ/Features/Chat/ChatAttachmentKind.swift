import Foundation
import UniformTypeIdentifiers

enum ChatAttachmentKind: Equatable, Sendable {
    case image
    case document(ChatDocumentFormat)
    case unsupported

    var documentFormat: ChatDocumentFormat? {
        guard case .document(let format) = self else { return nil }
        return format
    }
}

struct ChatAttachmentPreviewFile: Sendable {
    let url: URL
    let directoryURL: URL

    @concurrent
    static func create(
        for attachment: ChatImageAttachment,
        in temporaryDirectory: URL = .temporaryDirectory
    ) async throws -> Self {
        guard let data = Data(base64Encoded: attachment.base64Data) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try Task.checkCancellation()

        let directoryURL = temporaryDirectory
            .appending(path: "NativChatPreviews", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directoryURL.appending(
            path: safeFilename(attachment.filename),
            directoryHint: .notDirectory
        )

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return Self(url: url, directoryURL: directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func safeFilename(_ filename: String) -> String {
        let filename = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty || filename == "." || filename == ".."
            ? "Attachment"
            : filename
    }
}

extension ChatImageAttachment {
    var fileExtension: String {
        filename.pathExtension
    }

    var chatAttachmentKind: ChatAttachmentKind {
        let normalizedMIMEType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !normalizedMIMEType.isEmpty,
           normalizedMIMEType != "application/octet-stream" {
            return Self.kind(
                for: UTType(mimeType: normalizedMIMEType),
                fileExtension: filename.pathExtension
            )
        }

        return Self.kind(
            for: UTType(filenameExtension: filename.pathExtension),
            fileExtension: filename.pathExtension
        )
    }

    private static func kind(for type: UTType?, fileExtension: String) -> ChatAttachmentKind {
        if type?.conforms(to: .image) == true {
            return .image
        }
        if type?.conforms(to: .pdf) == true {
            return .document(.pdf)
        }
        if type?.conforms(to: .commaSeparatedText) == true {
            return .document(.csv)
        }
        if type?.conforms(to: .rtf) == true {
            return .document(.richText)
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true {
            return .document(.plainText)
        }

        switch fileExtension {
        case "pdf": return .document(.pdf)
        case "csv": return .document(.csv)
        case "rtf": return .document(.richText)
        case "doc", "docx": return .document(.wordProcessing)
        case "pptx": return .document(.presentation)
        case "txt", "md", "markdown", "json", "jsonl", "xml", "html", "htm",
             "css", "js", "jsx", "ts", "tsx", "swift", "py", "rb", "rs", "go",
             "java", "kt", "kts", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm",
             "sh", "bash", "zsh", "fish", "sql", "yaml", "yml", "toml", "ini", "cfg",
             "conf", "env", "log":
            return .document(.plainText)
        default:
            return .unsupported
        }
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension.lowercased()
    }
}
