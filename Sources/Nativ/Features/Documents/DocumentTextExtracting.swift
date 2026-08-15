import Foundation

protocol DocumentTextExtracting: Sendable {
    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent
}

enum DocumentTextExtractionError: Error, Equatable, Sendable {
    case emptyData
    case invalidDocument
    case passwordProtected
    case noExtractableText
}

extension DocumentTextExtractionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyData:
            "The document is empty."
        case .invalidDocument:
            "The file is not a readable document."
        case .passwordProtected:
            "The document is password-protected and must be unlocked before its text can be extracted."
        case .noExtractableText:
            "The document does not contain extractable text."
        }
    }
}
