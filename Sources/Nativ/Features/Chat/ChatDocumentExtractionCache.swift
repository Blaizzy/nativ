import Foundation
import OSLog

struct IndexedChatDocument: Sendable {
    let content: ExtractedDocumentContent
    let format: ChatDocumentFormat
    let sectionIndexesByTerm: [String: [Int]]

    init(_ content: ExtractedDocumentContent, format: ChatDocumentFormat) {
        self.content = content
        self.format = format

        var sectionIndexesByTerm: [String: [Int]] = [:]
        for (index, section) in content.sections.enumerated() {
            let terms = Set(Self.tokens(in: section.text))
            for term in terms {
                sectionIndexesByTerm[term, default: []].append(index)
            }
        }
        self.sectionIndexesByTerm = sectionIndexesByTerm
    }

    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { substring, _, _, _ in
            guard let substring else { return }
            let token = normalized(substring)
            if token.contains(where: { $0.isLetter || $0.isNumber }) {
                tokens.append(token)
            }
        }
        return tokens
    }

    static func normalized(_ token: String) -> String {
        token.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

/// Shares complete document extraction results between validation and request construction.
actor ChatDocumentExtractionCache {
    private static let signposter = OSSignposter(
        subsystem: "com.nativ.app",
        category: "DocumentExtraction"
    )

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

        let task = Task { [extract] in
            let signpostID = Self.signposter.makeSignpostID()
            let state = Self.signposter.beginInterval(
                "Extract and index document",
                id: signpostID
            )
            defer { Self.signposter.endInterval("Extract and index document", state) }
            let content = try await extract(
                data,
                attachment.filename,
                attachment.mimeType,
                format
            )
            return IndexedChatDocument(content, format: format)
        }
        extractionTasks[attachment.id] = task

        defer { extractionTasks[attachment.id] = nil }
        let document = try await task.value
        documents[attachment.id] = document
        try Task.checkCancellation()
        return document
    }
}
