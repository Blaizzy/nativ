import CoreGraphics
import CoreText
import PDFKit
import XCTest

final class PDFDocumentTextExtractorTests: XCTestCase {
    private let extractor = PDFDocumentTextExtractor()

    func testExtractsTextAndSourceMetadata() async throws {
        let data = try makePDF(pages: ["Quarterly report\nRevenue increased by 12%."])

        let content = try await extractor.extract(
            data: data,
            filename: "report.pdf",
            mimeType: "application/pdf"
        )

        XCTAssertEqual(content.filename, "report.pdf")
        XCTAssertEqual(content.mimeType, "application/pdf")
        XCTAssertEqual(content.pageCount, 1)
        XCTAssertEqual(
            content.sections,
            [
                ExtractedDocumentSection(
                    pageNumber: 1,
                    text: "Quarterly report\nRevenue increased by 12%."
                )
            ]
        )
        XCTAssertEqual(content.text, "Quarterly report\nRevenue increased by 12%.")
        XCTAssertEqual(content.characterCount, content.text.count)
    }

    func testPreservesPageOrderAndOmitsPagesWithoutText() async throws {
        let data = try makePDF(
            pages: [
                "First page",
                "   \n",
                "Third page",
            ]
        )

        let content = try await extractor.extract(
            data: data,
            filename: "pages.pdf",
            mimeType: "application/pdf"
        )

        XCTAssertEqual(content.pageCount, 3)
        XCTAssertEqual(content.sections.map(\.pageNumber), [1, 3])
        XCTAssertEqual(content.sections.map(\.text), ["First page", "Third page"])
        XCTAssertEqual(content.text, "First page\n\nThird page")
    }

    func testPreservesUnicodeText() async throws {
        let expected = "Zażółć gęślą jaźń — こんにちは"
        let data = try makePDF(pages: [expected])

        let content = try await extractor.extract(
            data: data,
            filename: "unicode.pdf",
            mimeType: "application/pdf"
        )

        XCTAssertEqual(content.sections.map(\.text), [expected])
    }

    func testRejectsEmptyData() async {
        await assertExtractionError(.emptyData, data: Data())
    }

    func testRejectsInvalidPDFData() async {
        await assertExtractionError(
            .invalidDocument,
            data: Data("This is not a PDF".utf8)
        )
    }

    func testReportsPDFWithoutEmbeddedText() async throws {
        let data = try makePDF(pages: ["  \n  "])

        await assertExtractionError(.noExtractableText, data: data)
    }

    func testReportsPasswordProtectedPDF() async throws {
        let sourceData = try makePDF(pages: ["Confidential"])
        let source = try XCTUnwrap(PDFDocument(data: sourceData))
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner-password",
            .userPasswordOption: "user-password",
        ]
        let encryptedData = try XCTUnwrap(source.dataRepresentation(options: options))

        await assertExtractionError(.passwordProtected, data: encryptedData)
    }

    func testExtractedContentSupportsStableSerialization() async throws {
        let data = try makePDF(pages: ["One", "Two"])
        let content = try await extractor.extract(
            data: data,
            filename: "serializable.pdf",
            mimeType: "application/pdf"
        )

        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ExtractedDocumentContent.self, from: encoded)

        XCTAssertEqual(decoded, content)
    }

    func testHonorsTaskCancellation() async throws {
        let data = try makePDF(pages: ["Text"])
        let extractor = self.extractor
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await extractor.extract(
                data: data,
                filename: "cancelled.pdf",
                mimeType: "application/pdf"
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected extraction to stop after cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertExtractionError(
        _ expectedError: DocumentTextExtractionError,
        data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await extractor.extract(
                data: data,
                filename: "document.pdf",
                mimeType: "application/pdf"
            )
            XCTFail("Expected extraction to fail with \(expectedError)", file: file, line: line)
        } catch let error as DocumentTextExtractionError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makePDF(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 700)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(
            CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        )
        let font = try XCTUnwrap(
            CTFontCreateUIFontForLanguage(.system, 14, nil)
        )
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]

        for text in pages {
            context.beginPDFPage(nil)
            let attributedText = NSAttributedString(string: text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
            let textBounds = CGRect(x: 40, y: 40, width: 420, height: 620)
            let path = CGPath(rect: textBounds, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()

        return data as Data
    }
}
