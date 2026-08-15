import Foundation
import XCTest

final class ChatAttachmentValidatorTests: XCTestCase {
    func testClassifiesAttachmentsUsingMIMETypeAndFilename() {
        XCTAssertEqual(
            attachment(filename: "photo", mimeType: "image/png").chatAttachmentKind,
            .image
        )
        XCTAssertEqual(
            attachment(filename: "report.pdf", mimeType: "application/octet-stream")
                .chatAttachmentKind,
            .pdf
        )
        XCTAssertEqual(
            attachment(filename: "photo.png", mimeType: "application/pdf").chatAttachmentKind,
            .pdf
        )
        XCTAssertEqual(
            attachment(filename: "report.pdf", mimeType: "text/plain").chatAttachmentKind,
            .unsupported
        )
        XCTAssertEqual(
            attachment(filename: "notes.txt", mimeType: "text/plain").chatAttachmentKind,
            .unsupported
        )
    }

    func testImagesAreImmediatelyReady() {
        let image = attachment(filename: "photo.png", mimeType: "image/png")

        XCTAssertEqual(
            ChatAttachmentValidator.immediateValidation(for: image),
            .ready(extractedCharacterCount: nil)
        )
    }

    func testUnreadableImagesAreImmediatelyBlocked() {
        let image = ChatImageAttachment(
            filename: "photo.png",
            mimeType: "image/png",
            base64Data: "not-base64"
        )

        XCTAssertEqual(
            ChatAttachmentValidator.immediateValidation(for: image),
            .blocked(message: "“photo.png” is empty or couldn’t be read.")
        )
    }

    func testUnsupportedFormatsAreImmediatelyBlocked() throws {
        let spreadsheet = attachment(
            filename: "budget.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )

        let validation = try XCTUnwrap(
            ChatAttachmentValidator.immediateValidation(for: spreadsheet)
        )

        XCTAssertTrue(validation.preventsSending)
        guard case .blocked(let message) = validation else {
            return XCTFail("Expected unsupported attachment to be blocked")
        }
        XCTAssertTrue(message.contains("isn’t supported in chat yet"))
    }

    func testPDFWithoutEmbeddedTextExplainsOCRLimitation() async throws {
        let validator = validator(result: .failure(.noExtractableText))

        let validation = try await validator.validatePDF(attachment(filename: "scan.pdf"))

        guard case .blocked(let message) = validation else {
            return XCTFail("Expected scanned PDF to be blocked")
        }
        XCTAssertTrue(message.contains("no selectable text"))
        XCTAssertTrue(message.contains("OCR"))
    }

    func testPasswordProtectedPDFExplainsHowToProceed() async throws {
        let validator = validator(result: .failure(.passwordProtected))

        let validation = try await validator.validatePDF(attachment(filename: "private.pdf"))

        guard case .blocked(let message) = validation else {
            return XCTFail("Expected password-protected PDF to be blocked")
        }
        XCTAssertTrue(message.contains("password-protected"))
        XCTAssertTrue(message.contains("Unlock it"))
    }

    func testLongPDFWarnsWithoutBlockingSending() async throws {
        let content = ExtractedDocumentContent(
            filename: "long.pdf",
            mimeType: "application/pdf",
            pageCount: 1,
            sections: [ExtractedDocumentSection(pageNumber: 1, text: "123456")]
        )
        let validator = validator(
            result: .success(content),
            maximumCharactersPerDocument: 5
        )

        let validation = try await validator.validatePDF(attachment(filename: "long.pdf"))

        XCTAssertFalse(validation.preventsSending)
        XCTAssertEqual(validation.extractedCharacterCount, 6)
        guard case .warning(let message, _) = validation else {
            return XCTFail("Expected long PDF warning")
        }
        XCTAssertTrue(message.contains("Only the first 5 characters"))
    }

    func testReadablePDFIsReadyWithExtractedCharacterCount() async throws {
        let content = ExtractedDocumentContent(
            filename: "report.pdf",
            mimeType: "application/pdf",
            pageCount: 1,
            sections: [ExtractedDocumentSection(pageNumber: 1, text: "Report text")]
        )
        let validator = validator(result: .success(content))

        let validation = try await validator.validatePDF(attachment(filename: "report.pdf"))

        XCTAssertEqual(
            validation,
            .ready(extractedCharacterCount: "Report text".count)
        )
    }

    func testValidationPropagatesCancellation() async throws {
        let validator = validator(result: .failure(.invalidDocument))
        let pdf = attachment(filename: "report.pdf")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await validator.validatePDF(pdf)
        }

        do {
            _ = try await task.value
            XCTFail("Expected validation to stop after cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func attachment(
        filename: String,
        mimeType: String = "application/pdf"
    ) -> ChatImageAttachment {
        ChatImageAttachment(
            filename: filename,
            mimeType: mimeType,
            base64Data: Data("pdf-data".utf8).base64EncodedString()
        )
    }

    private func validator(
        result: Result<ExtractedDocumentContent, DocumentTextExtractionError>,
        maximumCharactersPerDocument: Int = ChatDocumentContextBuilder.defaultMaximumCharactersPerDocument
    ) -> ChatAttachmentValidator {
        let cache = ChatDocumentExtractionCache(
            maximumCharactersPerDocument: maximumCharactersPerDocument
        ) { _, _, _ in
            try result.get()
        }
        return ChatAttachmentValidator(extractionCache: cache)
    }
}
