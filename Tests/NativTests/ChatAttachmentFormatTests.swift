import Foundation
import XCTest

/// Covers the attachment side of document support: which files are accepted, which are
/// refused, and that damaged ones fail with a readable error rather than hanging.
final class ChatAttachmentFormatTests: XCTestCase {
    func testSupportedDocumentsResolveToAFormat() {
        let expected: [String: ChatDocumentFormat] = [
            "report.pdf": .pdf,
            "table.csv": .csv,
            "notes.rtf": .richText,
            "letter.doc": .wordProcessing,
            "letter.docx": .wordProcessing,
            "deck.pptx": .presentation,
            "run.ipynb": .notebook,
            "budget.xlsx": .spreadsheet,
            "sheet.ods": .openDocument,
            "notes.odt": .openDocument,
            "book.epub": .ebook,
        ]
        for (filename, format) in expected {
            XCTAssertEqual(
                attachment(filename: filename).chatAttachmentKind,
                .document(format),
                filename
            )
        }
    }

    func testUnsupportedDocumentsStayUnsupported() {
        for filename in ["legacy.xls", "legacy.ppt", "book.azw3", "archive.7z"] {
            XCTAssertEqual(
                attachment(filename: filename).chatAttachmentKind,
                .unsupported,
                filename
            )
        }
    }

    func testUnsupportedAttachmentsAreBlockedBeforeReading() throws {
        for filename in ["legacy.xls", "legacy.ppt"] {
            let validation = try XCTUnwrap(
                ChatAttachmentValidator.immediateValidation(
                    for: attachment(filename: filename)
                ),
                filename
            )
            XCTAssertTrue(validation.preventsSending, filename)
            guard case .blocked = validation else {
                return XCTFail("expected \(filename) to be blocked")
            }
        }
    }

    func testEveryAttachmentFormatHasAnExtractorRegistered() async {
        // A format with no extractor throws .unsupportedFormat from the router itself, so a
        // filename matching each format proves one is registered whatever else goes wrong.
        let probes: [(ChatDocumentFormat, String)] = [
            (.pdf, "probe.pdf"),
            (.plainText, "probe.txt"),
            (.csv, "probe.csv"),
            (.richText, "probe.rtf"),
            (.wordProcessing, "probe.docx"),
            (.presentation, "probe.pptx"),
            (.notebook, "probe.ipynb"),
            (.spreadsheet, "probe.xlsx"),
            (.openDocument, "probe.odt"),
            (.ebook, "probe.epub"),
        ]
        let router = DocumentTextExtractionRouter()
        for (format, filename) in probes {
            do {
                _ = try await router.extract(
                    data: Data("stub".utf8),
                    filename: filename,
                    mimeType: "application/octet-stream",
                    format: format
                )
            } catch DocumentTextExtractionError.unsupportedFormat {
                XCTFail("no extractor registered for \(format)")
            } catch {
                continue
            }
        }
    }

    func testDamagedDocumentsFailWithAReadableError() async throws {
        let cases: [(String, ChatDocumentFormat, Data)] = [
            ("broken.ipynb", .notebook, Data("not valid json at all".utf8)),
            ("empty.epub", .ebook, Data()),
            ("corrupt.xlsx", .spreadsheet, Data(repeating: 0x41, count: 2_048)),
            ("corrupt.ods", .openDocument, Data(repeating: 0x42, count: 2_048)),
        ]
        let router = DocumentTextExtractionRouter()
        for (filename, format, data) in cases {
            do {
                _ = try await router.extract(
                    data: data,
                    filename: filename,
                    mimeType: "application/octet-stream",
                    format: format
                )
                XCTFail("expected \(filename) to fail")
            } catch let error as DocumentTextExtractionError {
                XCTAssertFalse(
                    error.localizedDescription.isEmpty,
                    "\(filename) produced an empty message"
                )
            }
        }
    }

    private func attachment(filename: String) -> ChatImageAttachment {
        ChatImageAttachment(
            filename: filename,
            mimeType: "application/octet-stream",
            base64Data: Data("stub".utf8).base64EncodedString()
        )
    }
}
