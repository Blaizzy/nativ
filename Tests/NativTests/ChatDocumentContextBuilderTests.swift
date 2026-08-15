import Foundation
import NativServerKit
import XCTest

final class ChatDocumentContextBuilderTests: XCTestCase {
    func testBuildsPageLabeledContextForPDFAttachment() async throws {
        let message = userMessage(
            content: "Summarize this report.",
            attachments: [attachment(filename: "report.pdf")]
        )
        let builder = builder(contents: [
            "report.pdf": ExtractedDocumentContent(
                filename: "report.pdf",
                mimeType: "application/pdf",
                pageCount: 3,
                sections: [
                    ExtractedDocumentSection(pageNumber: 1, text: "First page"),
                    ExtractedDocumentSection(pageNumber: 3, text: "Third page"),
                ]
            )
        ])

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("--- Begin attached document: report.pdf ---"))
        XCTAssertTrue(context.contains("[Page 1]\nFirst page"))
        XCTAssertTrue(context.contains("[Page 3]\nThird page"))
        XCTAssertTrue(context.contains("--- End attached document: report.pdf ---"))
    }

    func testAppliesPerDocumentLimitAndMarksTruncatedContent() async throws {
        let message = userMessage(attachments: [attachment(filename: "long.pdf")])
        let builder = builder(
            contents: [
                "long.pdf": content(filename: "long.pdf", text: "abcdefghij")
            ],
            maximumCharactersPerDocument: 4,
            maximumCharactersPerRequest: 100
        )

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("[Page 1]\nabcd"))
        XCTAssertFalse(context.contains("abcde"))
        XCTAssertTrue(context.contains("[Document truncated to fit the chat context limit.]"))
    }

    func testRequestLimitPrioritizesNewestMessages() async throws {
        let olderMessage = userMessage(attachments: [attachment(filename: "older.pdf")])
        let newerMessage = userMessage(attachments: [attachment(filename: "newer.pdf")])
        let builder = builder(
            contents: [
                "older.pdf": content(filename: "older.pdf", text: "older"),
                "newer.pdf": content(filename: "newer.pdf", text: "newer"),
            ],
            maximumCharactersPerDocument: 10,
            maximumCharactersPerRequest: 5
        )

        let contexts = try await builder.contexts(for: [olderMessage, newerMessage])

        XCTAssertNil(contexts[olderMessage.id])
        XCTAssertTrue(try XCTUnwrap(contexts[newerMessage.id]).contains("newer"))
    }

    func testRecognizesPDFByMIMETypeOrFilenameExtension() async throws {
        let mimeTypeAttachment = attachment(
            filename: "mime-only",
            mimeType: "application/pdf"
        )
        let extensionAttachment = attachment(
            filename: "extension-only.pdf",
            mimeType: "application/octet-stream"
        )
        let imageAttachment = attachment(filename: "image.png", mimeType: "image/png")
        let message = userMessage(
            attachments: [mimeTypeAttachment, extensionAttachment, imageAttachment]
        )
        let extractor = RecordingDocumentTextExtractor()
        let builder = builder(extract: extractor.extract)

        _ = try await builder.contexts(for: [message])

        let filenames = await extractor.filenames
        XCTAssertEqual(filenames, ["mime-only", "extension-only.pdf"])
    }

    func testSanitizesFilenameUsedInDocumentDelimiters() async throws {
        let filename = "quarterly\nreport.pdf"
        let message = userMessage(attachments: [attachment(filename: filename)])
        let builder = builder(contents: [
            filename: content(filename: filename, text: "Results")
        ])

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("Begin attached document: quarterly report.pdf"))
        XCTAssertFalse(context.contains("Begin attached document: quarterly\nreport.pdf"))
    }

    func testSkipsInvalidAttachmentDataAndExtractionFailures() async throws {
        let invalidData = ChatImageAttachment(
            filename: "invalid.pdf",
            mimeType: "application/pdf",
            base64Data: "not-base64"
        )
        let message = userMessage(
            attachments: [
                invalidData,
                attachment(filename: "unreadable.pdf"),
                attachment(filename: "readable.pdf"),
            ]
        )
        let builder = builder(contents: [
            "readable.pdf": content(filename: "readable.pdf", text: "Available text")
        ])

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("Available text"))
        XCTAssertFalse(context.contains("invalid.pdf"))
        XCTAssertFalse(context.contains("unreadable.pdf"))
    }

    func testPropagatesCancellation() async throws {
        let message = userMessage(attachments: [attachment(filename: "report.pdf")])
        let builder = builder(contents: [:])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await builder.contexts(for: [message])
        }

        do {
            _ = try await task.value
            XCTFail("Expected context building to stop after cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAddsDocumentContextToTextOnlyAPIMessage() throws {
        let message = userMessage(content: "Create a report.")

        let apiMessage = try XCTUnwrap(
            message.apiMessage(documentContext: "Attached document context")
        )

        XCTAssertEqual(
            apiMessage.content,
            .text("Create a report.\n\nAttached document context")
        )
        XCTAssertEqual(message.content, "Create a report.")
    }

    func testAddsDocumentContextToTextPartWithoutRemovingImages() throws {
        let image = attachment(filename: "chart.png", mimeType: "image/png")
        let message = userMessage(content: "Explain this.", attachments: [image])

        let apiMessage = try XCTUnwrap(
            message.apiMessage(documentContext: "Attached document context")
        )

        XCTAssertEqual(
            apiMessage.content,
            .parts([
                MLXChatContentPart(text: "Explain this.\n\nAttached document context"),
                MLXChatContentPart(imageURL: image.dataURL),
            ])
        )
    }

    func testCanExcludeImagesWhileKeepingTextAndDocumentContext() throws {
        let message = userMessage(
            content: "Summarize the document.",
            attachments: [attachment(filename: "photo.png", mimeType: "image/png")]
        )

        let apiMessage = try XCTUnwrap(
            message.apiMessage(
                documentContext: "Attached document context",
                includesImages: false
            )
        )

        XCTAssertEqual(
            apiMessage.content,
            .text("Summarize the document.\n\nAttached document context")
        )
    }

    func testValidationAndRequestConstructionShareOneExtraction() async throws {
        let attachment = attachment(filename: "report.pdf")
        let message = userMessage(
            content: "Summarize this report.",
            attachments: [attachment]
        )
        let extractor = CountingDocumentTextExtractor(
            content: content(filename: "report.pdf", text: "Report contents")
        )
        let extractionCache = ChatDocumentExtractionCache(extract: extractor.extract)
        let validator = ChatAttachmentValidator(extractionCache: extractionCache)
        let builder = ChatDocumentContextBuilder(extractionCache: extractionCache)

        _ = try await validator.validatePDF(attachment)
        let contexts = try await builder.contexts(for: [message])
        let extractionCount = await extractor.extractionCount

        XCTAssertEqual(extractionCount, 1)
        XCTAssertTrue(try XCTUnwrap(contexts[message.id]).contains("Report contents"))
    }

    private func userMessage(
        content: String = "",
        attachments: [ChatImageAttachment] = []
    ) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            role: .user,
            content: content,
            imageAttachments: attachments
        )
    }

    private func attachment(
        filename: String,
        mimeType: String = "application/pdf"
    ) -> ChatImageAttachment {
        ChatImageAttachment(
            filename: filename,
            mimeType: mimeType,
            base64Data: Data("test-data".utf8).base64EncodedString()
        )
    }

    private func content(filename: String, text: String) -> ExtractedDocumentContent {
        ExtractedDocumentContent(
            filename: filename,
            mimeType: "application/pdf",
            pageCount: 1,
            sections: [ExtractedDocumentSection(pageNumber: 1, text: text)]
        )
    }

    private func builder(
        contents: [String: ExtractedDocumentContent],
        maximumCharactersPerDocument: Int = ChatDocumentContextBuilder.defaultMaximumCharactersPerDocument,
        maximumCharactersPerRequest: Int = ChatDocumentContextBuilder.defaultMaximumCharactersPerRequest
    ) -> ChatDocumentContextBuilder {
        builder(
            maximumCharactersPerDocument: maximumCharactersPerDocument,
            maximumCharactersPerRequest: maximumCharactersPerRequest
        ) { _, filename, _ in
            guard let content = contents[filename] else {
                throw DocumentTextExtractionError.invalidDocument
            }
            return content
        }
    }

    private func builder(
        maximumCharactersPerDocument: Int = ChatDocumentContextBuilder.defaultMaximumCharactersPerDocument,
        maximumCharactersPerRequest: Int = ChatDocumentContextBuilder.defaultMaximumCharactersPerRequest,
        extract: @escaping ChatDocumentExtractionCache.Extraction
    ) -> ChatDocumentContextBuilder {
        let cache = ChatDocumentExtractionCache(
            maximumCharactersPerDocument: maximumCharactersPerDocument,
            extract: extract
        )
        return ChatDocumentContextBuilder(
            extractionCache: cache,
            maximumCharactersPerRequest: maximumCharactersPerRequest
        )
    }
}

private actor RecordingDocumentTextExtractor {
    private(set) var filenames: [String] = []

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        filenames.append(filename)
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            pageCount: 1,
            sections: [ExtractedDocumentSection(pageNumber: 1, text: filename)]
        )
    }
}

private actor CountingDocumentTextExtractor {
    let content: ExtractedDocumentContent
    private(set) var extractionCount = 0

    init(content: ExtractedDocumentContent) {
        self.content = content
    }

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        extractionCount += 1
        return content
    }
}
