import Foundation

enum ChatAttachmentValidation: Equatable, Sendable {
    case processing(message: String)
    case ready(extractedCharacterCount: Int?)
    case warning(message: String, extractedCharacterCount: Int?)
    case blocked(message: String)

    var preventsSending: Bool {
        switch self {
        case .processing, .blocked:
            true
        case .ready, .warning:
            false
        }
    }

    var extractedCharacterCount: Int? {
        switch self {
        case .ready(let count), .warning(_, let count):
            count
        case .processing, .blocked:
            nil
        }
    }
}

actor ChatAttachmentValidator {
    private let extractionCache: ChatDocumentExtractionCache
    private let maximumCharactersPerDocument: Int

    init(extractionCache: ChatDocumentExtractionCache) {
        self.extractionCache = extractionCache
        self.maximumCharactersPerDocument = extractionCache.maximumCharactersPerDocument
    }

    nonisolated static func immediateValidation(
        for attachment: ChatImageAttachment
    ) -> ChatAttachmentValidation? {
        switch attachment.chatAttachmentKind {
        case .image:
            guard let data = Data(base64Encoded: attachment.base64Data), !data.isEmpty else {
                return .blocked(message: "“\(attachment.filename)” is empty or couldn’t be read.")
            }
            return .ready(extractedCharacterCount: nil)
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
            let document = try await extractionCache.document(for: attachment)
            try Task.checkCancellation()
            guard document.sourceCharacterCount > maximumCharactersPerDocument else {
                return .ready(extractedCharacterCount: document.sourceCharacterCount)
            }
            let formattedLimit = maximumCharactersPerDocument.formatted()
            return .warning(
                message: "“\(attachment.filename)” is long. "
                    + "Only the first \(formattedLimit) characters will be included.",
                extractedCharacterCount: document.sourceCharacterCount
            )
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
