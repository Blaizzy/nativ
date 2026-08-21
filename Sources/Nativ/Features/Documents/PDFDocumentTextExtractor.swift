import Foundation
import PDFKit

struct ExtractedDocumentSection: Codable, Equatable, Sendable {
    /// A one-based page number when the source format has pages.
    let pageNumber: Int?
    let text: String
}

struct ExtractedDocumentContent: Codable, Equatable, Sendable {
    let filename: String
    let mimeType: String
    /// The total number of pages in the source document, including pages without extractable text.
    let pageCount: Int?
    /// Extracted sections in source order. Empty sections are omitted.
    let sections: [ExtractedDocumentSection]

    var text: String {
        sections.map(\.text).joined(separator: "\n\n")
    }

    /// The number of source characters, excluding separators added by `text`.
    var characterCount: Int {
        sections.reduce(0) { $0 + $1.text.count }
    }
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

/// Extracts the embedded text layer from PDF documents.
///
/// PDFKit objects remain isolated to this actor because they are not `Sendable`.
actor PDFDocumentTextExtractor {
    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()

        guard !data.isEmpty else {
            throw DocumentTextExtractionError.emptyData
        }
        guard let document = PDFDocument(data: data) else {
            throw DocumentTextExtractionError.invalidDocument
        }
        guard !document.isLocked else {
            throw DocumentTextExtractionError.passwordProtected
        }

        var sections: [ExtractedDocumentSection] = []
        sections.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            let pageText = autoreleasepool {
                document.page(at: pageIndex)?.string
            }
            guard let text = Self.normalized(pageText) else {
                continue
            }
            sections.append(
                ExtractedDocumentSection(pageNumber: pageIndex + 1, text: text)
            )
        }

        guard !sections.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }

        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            pageCount: document.pageCount,
            sections: sections
        )
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let normalized = text
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
