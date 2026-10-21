import Foundation
import UniformTypeIdentifiers
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

    func testKnownExtensionWinsOverGenericTextConformance() {
        // A notebook is JSON, which conforms to UTType.text. Resolving by conformance before
        // the extension would send it to plain text extraction with its base64 image outputs
        // intact, which is the thing the notebook extractor exists to avoid.
        let notebook = ChatImageAttachment(
            filename: "run.ipynb",
            mimeType: "application/json",
            base64Data: Data("stub".utf8).base64EncodedString()
        )
        XCTAssertEqual(notebook.chatAttachmentKind, .document(.notebook))

        let csv = ChatImageAttachment(
            filename: "table.csv",
            mimeType: "text/csv",
            base64Data: Data("stub".utf8).base64EncodedString()
        )
        XCTAssertEqual(csv.chatAttachmentKind, .document(.csv))
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

    func testEveryMappedExtensionCanBeOfferedInTheFilePicker() {
        // chooseAttachments builds its allowed types from this map. An extension with no
        // resolvable UTType would be silently unselectable in the picker, which is how
        // notebooks ended up never reaching the model.
        for fileExtension in ChatDocumentFormat.formatsByFileExtension.keys {
            XCTAssertNotNil(
                UTType(filenameExtension: fileExtension),
                "\(fileExtension) has no UTType, so the picker cannot offer it"
            )
        }
    }

    func testNotebookAttachmentReachesTheRequestContext() async throws {
        let notebook = """
        {"cells":[{"cell_type":"code","source":["import numpy as np\\n","print(42)"],\
        "outputs":[{"output_type":"display_data","data":{"image/png":"iVBORw0KGgoAAAA"}}]}]}
        """
        let attachment = ChatImageAttachment(
            filename: "run.ipynb",
            mimeType: "application/json",
            base64Data: Data(notebook.utf8).base64EncodedString()
        )
        XCTAssertEqual(attachment.chatAttachmentKind, .document(.notebook))

        let cache = ChatDocumentExtractionCache()
        let validator = ChatAttachmentValidator(extractionCache: cache)
        let validation = try await validator.validateDocument(attachment)
        XCTAssertEqual(validation, .ready)

        let message = ChatTranscriptMessage(
            id: UUID(),
            role: .user,
            content: "what does this notebook do?",
            imageAttachments: [attachment]
        )
        let result = try await ChatDocumentContextBuilder(extractionCache: cache)
            .contexts(for: [message])
        let context = try XCTUnwrap(result[message.id])

        XCTAssertTrue(context.contains("import numpy as np"))
        XCTAssertFalse(context.contains("iVBORw0KGgo"))
    }

    private func attachment(filename: String) -> ChatImageAttachment {
        ChatImageAttachment(
            filename: filename,
            mimeType: "application/octet-stream",
            base64Data: Data("stub".utf8).base64EncodedString()
        )
    }
}
