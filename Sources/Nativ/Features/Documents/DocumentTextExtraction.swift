import Foundation

enum ChatDocumentFormat: Hashable, Sendable {
    case pdf
    case plainText
    case csv
    case richText
    case wordProcessing
    case presentation
    case notebook
    case openDocument
    case ebook
    case spreadsheet
}

extension ChatDocumentFormat {
    /// File extensions that resolve to a document format.
    ///
    /// CSV maps to plain text extraction; the separate case exists only so the context
    /// builder can pin a table's header row when it selects sections.
    static let formatsByFileExtension: [String: ChatDocumentFormat] = [
        "pdf": .pdf,
        "csv": .csv,
        "rtf": .richText,
        "doc": .wordProcessing,
        "docx": .wordProcessing,
        "pptx": .presentation,
        "ipynb": .notebook,
        "odt": .openDocument,
        "ods": .openDocument,
        "epub": .ebook,
        "xlsx": .spreadsheet,
    ]

    static func forFileExtension(_ fileExtension: String) -> ChatDocumentFormat? {
        formatsByFileExtension[fileExtension.lowercased()]
    }
}

enum ExtractedDocumentLocation: Codable, Equatable, Sendable {
    case page(Int)
    case slide(Int)
    case lines(Int, Int)
    case named(String)

    var label: String {
        switch self {
        case .page(let number):
            "Page \(number)"
        case .slide(let number):
            "Slide \(number)"
        case .lines(let first, let last):
            first == last ? "Line \(first)" : "Lines \(first)–\(last)"
        case .named(let label):
            label
        }
    }

    func matches(pages: Set<Int>, slides: Set<Int>, lines: Set<Int>) -> Bool {
        switch self {
        case .page(let number):
            pages.contains(number)
        case .slide(let number):
            slides.contains(number)
        case .lines(let first, let last):
            lines.contains { first...last ~= $0 }
        case .named:
            false
        }
    }
}

struct ExtractedDocumentSection: Codable, Equatable, Sendable {
    let location: ExtractedDocumentLocation
    let text: String
}

struct ExtractedDocumentContent: Codable, Equatable, Sendable {
    let filename: String
    let mimeType: String
    /// Includes source sections without extractable text, such as blank PDF pages.
    let sourceSectionCount: Int
    /// Extracted sections in source order. Empty sections are omitted.
    let sections: [ExtractedDocumentSection]

    var text: String {
        sections.map(\.text).joined(separator: "\n\n")
    }

    var characterCount: Int {
        sections.reduce(0) { $0 + $1.text.count }
    }

    var sectionName: String {
        switch sections.first?.location {
        case .page: "pages"
        case .slide: "slides"
        default: "sections"
        }
    }
}

enum DocumentTextExtractionError: Error, Equatable, Sendable {
    case emptyData
    case invalidDocument
    case passwordProtected
    case noExtractableText
    case unsupportedFormat
    case archiveTooLarge
}

extension DocumentTextExtractionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyData:
            "The document is empty."
        case .invalidDocument:
            "The file is not a readable document."
        case .passwordProtected:
            "The document is password-protected and must be unlocked first."
        case .noExtractableText:
            "The document does not contain extractable text."
        case .unsupportedFormat:
            "This document format is not supported."
        case .archiveTooLarge:
            "The document expands beyond the safe processing limit."
        }
    }
}

protocol DocumentTextExtracting: Sendable {
    var formats: Set<ChatDocumentFormat> { get }

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent
}

struct DocumentTextExtractionRouter: Sendable {
    private let extractors: [any DocumentTextExtracting]

    init(extractors: [any DocumentTextExtracting] = Self.defaults) {
        self.extractors = extractors
    }

    func extract(
        data: Data,
        filename: String,
        mimeType: String,
        format: ChatDocumentFormat
    ) async throws -> ExtractedDocumentContent {
        guard let extractor = extractors.first(where: { $0.formats.contains(format) }) else {
            throw DocumentTextExtractionError.unsupportedFormat
        }
        return try await extractor.extract(data: data, filename: filename, mimeType: mimeType)
    }

    private static var defaults: [any DocumentTextExtracting] {
        [
            PDFDocumentTextExtractor(),
            PlainTextDocumentTextExtractor(),
            RichTextDocumentTextExtractor(),
            PowerPointDocumentTextExtractor(),
            NotebookDocumentTextExtractor(),
            OpenDocumentTextExtractor(),
            EPUBDocumentTextExtractor(),
            SpreadsheetDocumentTextExtractor(),
        ]
    }
}
