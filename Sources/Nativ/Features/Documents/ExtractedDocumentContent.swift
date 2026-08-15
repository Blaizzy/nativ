import Foundation

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
