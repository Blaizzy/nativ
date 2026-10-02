import Foundation
import ZIPFoundation

/// Extracts text from OpenDocument text and spreadsheet files, which both store their
/// content in a single `content.xml`.
actor OpenDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.openDocument]

    private static let contentLimit: UInt64 = 32 * 1_024 * 1_024

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }

        let archive = try OfficeArchive.open(data)
        guard let entry = archive["content.xml"] else {
            throw DocumentTextExtractionError.invalidDocument
        }
        let content = try ArchiveEntryData.read(entry, in: archive, limit: Self.contentLimit)

        let delegate = ElementTextParser(
            textElements: ["p", "h", "span", "a", "list-item"],
            blockElements: ["p", "h", "list-item", "table-row"]
        )
        try ArchiveEntryData.parse(content, with: delegate)
        let text = delegate.text
        guard !text.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }

        return try TextDocumentContent.make(
            text: text,
            filename: filename,
            mimeType: mimeType
        )
    }
}
