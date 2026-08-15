import Foundation

/// Shares bounded PDF extraction results between attachment validation and request construction.
actor ChatDocumentExtractionCache {
    struct Document: Sendable {
        let content: ExtractedDocumentContent
        let sourceCharacterCount: Int
    }

    nonisolated let maximumCharactersPerDocument: Int

    private let extractor: any DocumentTextExtracting
    private var documents: [UUID: Document] = [:]
    private var extractionTasks: [UUID: Task<Document, Error>] = [:]

    init(
        extractor: any DocumentTextExtracting = PDFDocumentTextExtractor(),
        maximumCharactersPerDocument: Int = ChatDocumentContextBuilder.defaultMaximumCharactersPerDocument
    ) {
        precondition(maximumCharactersPerDocument > 0)
        self.extractor = extractor
        self.maximumCharactersPerDocument = maximumCharactersPerDocument
    }

    func document(for attachment: ChatImageAttachment) async throws -> Document {
        try Task.checkCancellation()
        if let document = documents[attachment.id] {
            return document
        }
        if let task = extractionTasks[attachment.id] {
            let document = try await task.value
            try Task.checkCancellation()
            return document
        }
        guard attachment.chatAttachmentKind == .pdf,
              let data = Data(base64Encoded: attachment.base64Data)
        else {
            throw DocumentTextExtractionError.invalidDocument
        }

        let extractor = self.extractor
        let characterLimit = maximumCharactersPerDocument
        let task = Task {
            let content = try await extractor.extract(
                data: data,
                filename: attachment.filename,
                mimeType: attachment.mimeType
            )
            return Self.boundedDocument(from: content, characterLimit: characterLimit)
        }
        extractionTasks[attachment.id] = task

        do {
            let document = try await task.value
            documents[attachment.id] = document
            extractionTasks[attachment.id] = nil
            try Task.checkCancellation()
            return document
        } catch {
            extractionTasks[attachment.id] = nil
            throw error
        }
    }

    private nonisolated static func boundedDocument(
        from content: ExtractedDocumentContent,
        characterLimit: Int
    ) -> Document {
        var remainingCharacters = characterLimit
        let sections = content.sections.compactMap { section -> ExtractedDocumentSection? in
            guard remainingCharacters > 0 else {
                return nil
            }
            let text = String(section.text.prefix(remainingCharacters))
            remainingCharacters -= text.count
            return text.isEmpty ? nil : ExtractedDocumentSection(
                pageNumber: section.pageNumber,
                text: text
            )
        }
        return Document(
            content: ExtractedDocumentContent(
                filename: content.filename,
                mimeType: content.mimeType,
                pageCount: content.pageCount,
                sections: sections
            ),
            sourceCharacterCount: content.characterCount
        )
    }
}
