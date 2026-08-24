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
        case .pdf:
            return nil
        case .unsupported:
            return .blocked(
                message: "“\(attachment.filename)” isn’t supported in chat yet. Attach a PDF or an image instead."
            )
        }
    }

    func validatePDF(_ attachment: ChatImageAttachment) async throws -> ChatAttachmentValidation {
        try Task.checkCancellation()
        guard attachment.chatAttachmentKind == .pdf else {
            return .blocked(message: "“\(attachment.filename)” couldn’t be read as a PDF.")
        }

        do {
            _ = try await extractionCache.document(for: attachment)
            try Task.checkCancellation()
            return .ready
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DocumentTextExtractionError {
            return .blocked(message: Self.message(for: error, filename: attachment.filename))
        } catch {
            return .blocked(
                message: "“\(attachment.filename)” couldn’t be processed: \(error.localizedDescription)"
            )
        }
    }

    private nonisolated static func message(
        for error: DocumentTextExtractionError,
        filename: String
    ) -> String {
        switch error {
        case .emptyData:
            "“\(filename)” is empty."
        case .invalidDocument:
            "“\(filename)” couldn’t be read as a PDF."
        case .passwordProtected:
            "“\(filename)” is password-protected. Unlock it before attaching it."
        case .noExtractableText:
            "“\(filename)” has no selectable text. OCR for scanned PDFs isn’t supported yet."
        }
    }
}
