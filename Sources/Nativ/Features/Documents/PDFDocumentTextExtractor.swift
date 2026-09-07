import PDFKit

/// Extracts the embedded text layer from PDF documents.
///
/// PDFKit objects remain isolated to this actor because they are not `Sendable`.
actor PDFDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.pdf]

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
                ExtractedDocumentSection(location: .page(pageIndex + 1), text: text)
            )
        }

        guard !sections.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }

        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: document.pageCount,
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
