import Foundation

struct IndexedChatDocument: Sendable {
    let content: ExtractedDocumentContent
    let termsBySection: [Set<String>]

    init(_ content: ExtractedDocumentContent) {
        self.content = content
        termsBySection = content.sections.map { Set(Self.tokens(in: $0.text)) }
    }

    static func tokens(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Shares complete document extraction results between validation and request construction.
actor ChatDocumentExtractionCache {
    typealias Extraction = @Sendable (
        _ data: Data,
        _ filename: String,
        _ mimeType: String,
        _ format: ChatDocumentFormat
    ) async throws -> ExtractedDocumentContent

    private let extract: Extraction
    private var documents: [UUID: IndexedChatDocument] = [:]
    private var extractionTasks: [UUID: Task<IndexedChatDocument, Error>] = [:]

    init() {
        let router = DocumentTextExtractionRouter()
        self.extract = { data, filename, mimeType, format in
            try await router.extract(
                data: data,
                filename: filename,
                mimeType: mimeType,
                format: format
            )
        }
    }

    init(extract: @escaping Extraction) {
        self.extract = extract
    }

    func document(for attachment: ChatImageAttachment) async throws -> IndexedChatDocument {
        try Task.checkCancellation()
        if let document = documents[attachment.id] {
            return document
        }
        if let task = extractionTasks[attachment.id] {
            let document = try await task.value
            try Task.checkCancellation()
            return document
        }
        guard let format = attachment.chatAttachmentKind.documentFormat,
              let data = Data(base64Encoded: attachment.base64Data)
        else {
            throw DocumentTextExtractionError.invalidDocument
        }

        let task = Task {
            try await IndexedChatDocument(
                extract(data, attachment.filename, attachment.mimeType, format)
            )
        }
        extractionTasks[attachment.id] = task

        defer { extractionTasks[attachment.id] = nil }
        let document = try await task.value
        documents[attachment.id] = document
        try Task.checkCancellation()
        return document
    }
}
