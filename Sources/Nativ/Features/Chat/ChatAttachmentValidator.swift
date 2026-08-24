import Foundation

enum ChatAttachmentValidation: Equatable, Sendable {
    case processing(message: String)
    case ready
    case blocked(message: String)

    var preventsSending: Bool {
        switch self {
        case .processing, .blocked:
            true
        case .ready:
            false
        }
    }
}

actor ChatAttachmentValidator {
    private let extractionCache: ChatDocumentExtractionCache

    init(extractionCache: ChatDocumentExtractionCache) {
        self.extractionCache = extractionCache
    }

    nonisolated static func immediateValidation(
        for attachment: ChatImageAttachment
    ) -> ChatAttachmentValidation? {
        switch attachment.chatAttachmentKind {
        case .image:
            guard let data = Data(base64Encoded: attachment.base64Data), !data.isEmpty else {
                return .blocked(message: "“\(attachment.filename)” is empty or couldn’t be read.")
            }
            return .ready
        case .document:
            return nil
        case .unsupported:
            return .blocked(
                message: "“\(attachment.filename)” isn’t supported in chat yet."
            )
        }
    }

    func validateDocument(_ attachment: ChatImageAttachment) async throws -> ChatAttachmentValidation {
        try Task.checkCancellation()
        guard let format = attachment.chatAttachmentKind.documentFormat else {
            return .blocked(message: "“\(attachment.filename)” couldn’t be read as a document.")
        }

        do {
            _ = try await extractionCache.document(for: attachment)
            try Task.checkCancellation()
            return .ready
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DocumentTextExtractionError {
            return .blocked(message: Self.message(
                for: error,
                filename: attachment.filename,
                format: format
            ))
        } catch {
            return .blocked(
                message: "“\(attachment.filename)” couldn’t be processed: \(error.localizedDescription)"
            )
        }
    }

    private nonisolated static func message(
        for error: DocumentTextExtractionError,
        filename: String,
        format: ChatDocumentFormat
    ) -> String {
        switch error {
        case .emptyData:
            "“\(filename)” is empty."
        case .invalidDocument:
            "“\(filename)” couldn’t be read as a document."
        case .passwordProtected:
            "“\(filename)” is password-protected. Unlock it before attaching it."
        case .noExtractableText:
            format == .pdf
                ? "“\(filename)” has no selectable text. OCR for scanned PDFs isn’t supported yet."
                : "“\(filename)” contains no readable text."
        case .unsupportedFormat:
            "“\(filename)” uses a document format that isn’t supported yet."
        case .archiveTooLarge:
            "“\(filename)” expands beyond the safe processing limit."
        }
    }
}
