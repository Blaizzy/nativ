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
                sourceSectionCount: 3,
                sections: [
                    ExtractedDocumentSection(location: .page(1), text: "First page"),
                    ExtractedDocumentSection(location: .page(3), text: "Third page"),
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

    func testAppliesPerDocumentLimitAndMarksSelectedExcerpts() async throws {
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
        XCTAssertTrue(context.contains("[Selected relevant excerpts from 1 of 1 pages.]"))
    }

    func testSelectsARelevantPageNearTheEndInsteadOfTheDocumentPrefix() async throws {
        let attachmentMessage = userMessage(
            content: "Read this report.",
            attachments: [attachment(filename: "long.pdf")]
        )
        let queryMessage = userMessage(content: "What changed about zephyr pricing?")
        let builder = builder(
            contents: [
                "long.pdf": content(filename: "long.pdf", pages: [
                    "Opening overview and agenda.",
                    "Background information.",
                    "Earlier pricing history.",
                    "Context immediately before the change.",
                    "Zephyr pricing increased by twelve percent.",
                    "Closing implementation notes.",
                ])
            ],
            maximumCharactersPerDocument: 90,
            maximumCharactersPerRequest: 90
        )

        let contexts = try await builder.contexts(for: [attachmentMessage, queryMessage])
        let context = try XCTUnwrap(contexts[attachmentMessage.id])

        XCTAssertTrue(context.contains("[Page 5]"))
        XCTAssertTrue(context.localizedCaseInsensitiveContains("zephyr pricing"))
        XCTAssertTrue(context.contains("[Page 4]") || context.contains("[Page 6]"))
        XCTAssertFalse(context.contains("Opening overview and agenda."))
    }

    func testExplicitPageReferenceWinsWithoutMatchingPageText() async throws {
        let message = userMessage(
            content: "Explain page 4.",
            attachments: [attachment(filename: "pages.pdf")]
        )
        let builder = builder(
            contents: [
                "pages.pdf": content(
                    filename: "pages.pdf",
                    pages: (1...6).map { "Unique content for section \($0)." }
                )
            ],
            maximumCharactersPerDocument: 90,
            maximumCharactersPerRequest: 90
        )

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("[Page 4]"))
        XCTAssertTrue(context.contains("Unique content for section 4."))
    }

    func testExplicitSlideReferenceWinsWithoutMatchingSlideText() async throws {
        let attachment = attachment(
            filename: "briefing.pptx",
            mimeType: "application/octet-stream"
        )
        let message = userMessage(content: "Explain slide 3.", attachments: [attachment])
        let content = ExtractedDocumentContent(
            filename: "briefing.pptx",
            mimeType: "application/octet-stream",
            sourceSectionCount: 4,
            sections: (1...4).map {
                ExtractedDocumentSection(location: .slide($0), text: "Content \($0)")
            }
        )
        let builder = builder(
            contents: ["briefing.pptx": content],
            maximumCharactersPerDocument: 30,
            maximumCharactersPerRequest: 30
        )

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("[Slide 3]"))
        XCTAssertTrue(context.contains("Content 3"))
    }

    func testFallbackSamplesAcrossDocumentWhenTheQueryHasNoMatchingTerms() async throws {
        let message = userMessage(
            content: "Summarize this PDF.",
            attachments: [attachment(filename: "pages.pdf")]
        )
        let builder = builder(
            contents: [
                "pages.pdf": content(
                    filename: "pages.pdf",
                    pages: (1...9).map { "Section \($0) has supporting details." }
                )
            ],
            maximumCharactersPerDocument: 75,
            maximumCharactersPerRequest: 75
        )

        let contexts = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(contexts[message.id])

        XCTAssertTrue(context.contains("[Page 1]"))
        XCTAssertTrue(context.contains("[Page 9]"))
        XCTAssertTrue(context.contains("[Page 5]"))
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
            content: "Where is the omega result?",
            attachments: [attachment]
        )
        let extractedContent = content(filename: "report.pdf", pages: [
            "A long introduction that fills the opening page.",
            "The omega result is forty-two.",
        ])
        let extractor = CountingDocumentTextExtractor(
            content: extractedContent
        )
        let extractionCache = ChatDocumentExtractionCache(extract: extractor.extract)
        let validator = ChatAttachmentValidator(extractionCache: extractionCache)
        let builder = ChatDocumentContextBuilder(
            extractionCache: extractionCache,
            maximumCharactersPerDocument: 24
        )

        let validation = try await validator.validateDocument(attachment)
        let contexts = try await builder.contexts(for: [message])
        let extractionCount = await extractor.extractionCount

        XCTAssertEqual(extractionCount, 1)
        XCTAssertEqual(validation, .ready)
        XCTAssertTrue(
            try XCTUnwrap(contexts[message.id]).localizedCaseInsensitiveContains("omega")
        )
    }

    func testLocalizedTokenizationRetrievesChineseSectionNearEnd() async throws {
        let attachmentMessage = userMessage(
            attachments: [attachment(filename: "research.txt", mimeType: "text/plain")]
        )
        let queryMessage = userMessage(content: "哈尔滨阵列的校准常数是多少？")
        let builder = builder(
            contents: [
                "research.txt": content(filename: "research.txt", pages: [
                    "项目背景和一般说明。",
                    "早期实验没有最终结果。",
                    "技术附录说明哈尔滨阵列的校准常数是 ZETA-42。",
                ])
            ],
            maximumCharactersPerDocument: 48,
            maximumCharactersPerRequest: 48
        )

        let result = try await builder.contexts(for: [attachmentMessage, queryMessage])

        XCTAssertTrue(try XCTUnwrap(result[attachmentMessage.id]).contains("ZETA-42"))
    }

    func testLocalizedTokenizationSegmentsUnspacedLanguages() {
        let samples = [
            "哈尔滨阵列的校准常数是多少",
            "配列の校正定数はいくつですか",
            "ค่าคงที่การสอบเทียบของอาร์เรย์คือเท่าใด",
        ]

        for sample in samples {
            XCTAssertGreaterThan(IndexedChatDocument.tokens(in: sample).count, 1, sample)
        }
    }

    func testIndexStoresOnlySectionsContainingEachTerm() {
        let document = IndexedChatDocument(
            content(filename: "facts.pdf", pages: [
                "alpha shared",
                "beta shared",
                "alpha gamma shared",
            ]),
            format: .pdf
        )

        XCTAssertEqual(document.sectionIndexesByTerm["alpha"], [0, 2])
        XCTAssertEqual(document.sectionIndexesByTerm["beta"], [1])
        XCTAssertEqual(document.sectionIndexesByTerm["shared"], [0, 1, 2])
    }

    func testRanksAllDirectMatchesBeforeTheirNeighbors() async throws {
        let attachmentMessage = userMessage(attachments: [attachment(filename: "facts.pdf")])
        let queryMessage = userMessage(content: "alpha beta")
        let builder = builder(
            contents: [
                "facts.pdf": content(filename: "facts.pdf", pages: [
                    "neighbor zero",
                    "alpha DIRECT-A",
                    "neighbor two",
                    "middle filler",
                    "neighbor four",
                    "beta DIRECT-B",
                    "neighbor six",
                ])
            ],
            maximumCharactersPerDocument: 45,
            maximumCharactersPerRequest: 45
        )

        let result = try await builder.contexts(for: [attachmentMessage, queryMessage])
        let context = try XCTUnwrap(result[attachmentMessage.id])

        XCTAssertTrue(context.contains("DIRECT-A"))
        XCTAssertTrue(context.contains("DIRECT-B"))
    }

    func testExcerptCentersOnDensestQueryTermCluster() async throws {
        let earlyStopword = "This is background. " + String(repeating: "filler ", count: 80)
        let answer = "Halden calibration constant ZETA-99"
        let message = userMessage(
            content: "What is the Halden calibration constant?",
            attachments: [attachment(filename: "dense.pdf")]
        )
        let builder = builder(
            contents: [
                "dense.pdf": content(filename: "dense.pdf", text: earlyStopword + answer)
            ],
            maximumCharactersPerDocument: 100,
            maximumCharactersPerRequest: 100
        )

        let result = try await builder.contexts(for: [message])

        XCTAssertTrue(try XCTUnwrap(result[message.id]).contains("ZETA-99"))
    }

    func testCSVHeaderIsPinnedBeforeRelevantRows() async throws {
        let document = attachment(filename: "sales.csv", mimeType: "text/csv")
        let message = userMessage(content: "Find zephyr revenue.", attachments: [document])
        let csv = ExtractedDocumentContent(
            filename: "sales.csv",
            mimeType: "text/csv",
            sourceSectionCount: 5,
            sections: [
                ExtractedDocumentSection(location: .lines(1, 1), text: "product,revenue"),
                ExtractedDocumentSection(location: .lines(2, 2), text: "atlas,10,regional filler"),
                ExtractedDocumentSection(location: .lines(3, 3), text: "nova,20,regional filler"),
                ExtractedDocumentSection(location: .lines(4, 4), text: "zephyr,42"),
                ExtractedDocumentSection(location: .lines(5, 5), text: "orion,30,regional filler"),
            ]
        )
        let builder = builder(
            contents: ["sales.csv": csv],
            maximumCharactersPerDocument: 48,
            maximumCharactersPerRequest: 48
        )

        let result = try await builder.contexts(for: [message])
        let context = try XCTUnwrap(result[message.id])

        XCTAssertTrue(context.contains("product,revenue"))
        XCTAssertTrue(context.contains("zephyr,42"))
    }

    func testReportsDocumentsOmittedByRequestLimit() async throws {
        let older = attachment(filename: "older.pdf")
        let newer = attachment(filename: "newer.pdf")
        let message = userMessage(attachments: [older, newer])
        let builder = builder(
            contents: [
                "older.pdf": content(filename: "older.pdf", text: "older"),
                "newer.pdf": content(filename: "newer.pdf", text: "newer"),
            ],
            maximumCharactersPerDocument: 5,
            maximumCharactersPerRequest: 5
        )

        let result = try await builder.contexts(for: [message])

        XCTAssertEqual(
            result.omittedDocuments,
            [ChatDocumentOmission(
                attachmentID: newer.id,
                filename: "newer.pdf",
                reason: .contextLimit
            )]
        )
    }

    func testTokenBudgetScalesCharactersUsingMeasuredDocumentTokens() {
        let limit = ChatDocumentTokenBudget.characterLimit(
            currentLimit: 48_000,
            basePromptTokens: 4_000,
            documentPromptTokens: 44_000,
            contextLimit: 32_000,
            maximumOutputTokens: 4_000
        )

        XCTAssertEqual(limit, 28_492)
    }

    func testTokenBudgetDropsDocumentsWhenBasePromptUsesAvailableContext() {
        let limit = ChatDocumentTokenBudget.characterLimit(
            currentLimit: 48_000,
            basePromptTokens: 30_000,
            documentPromptTokens: 40_000,
            contextLimit: 32_000,
            maximumOutputTokens: 4_000
        )

        XCTAssertEqual(limit, 0)
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
        content(filename: filename, pages: [text])
    }

    private func content(filename: String, pages: [String]) -> ExtractedDocumentContent {
        ExtractedDocumentContent(
            filename: filename,
            mimeType: "application/pdf",
            sourceSectionCount: pages.count,
            sections: pages.enumerated().map {
                ExtractedDocumentSection(location: .page($0.offset + 1), text: $0.element)
            }
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
        ) { _, filename, _, _ in
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
        let cache = ChatDocumentExtractionCache(extract: extract)
        return ChatDocumentContextBuilder(
            extractionCache: cache,
            maximumCharactersPerDocument: maximumCharactersPerDocument,
            maximumCharactersPerRequest: maximumCharactersPerRequest
        )
    }
}

private actor RecordingDocumentTextExtractor {
    private(set) var filenames: [String] = []

    func extract(
        data: Data,
        filename: String,
        mimeType: String,
        format: ChatDocumentFormat
    ) async throws -> ExtractedDocumentContent {
        filenames.append(filename)
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: 1,
            sections: [ExtractedDocumentSection(location: .page(1), text: filename)]
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
        mimeType: String,
        format: ChatDocumentFormat
    ) async throws -> ExtractedDocumentContent {
        extractionCount += 1
        return content
    }
}
