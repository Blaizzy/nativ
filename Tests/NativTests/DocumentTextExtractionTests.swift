import AppKit
import Foundation
import XCTest
import ZIPFoundation

final class DocumentTextExtractionTests: XCTestCase {
    func testPlainTextPreservesModelReadableMarkup() async throws {
        let source = "# Heading\n{\"enabled\":true}\n<item>value</item>"

        let content = try await DocumentTextExtractionRouter().extract(
            data: Data(source.utf8),
            filename: "notes.md",
            mimeType: "text/markdown",
            format: .plainText
        )

        XCTAssertEqual(content.sections.map(\.text).joined(separator: "\n"), source)
        XCTAssertEqual(content.sections.first?.location, .lines(1, 3))
    }

    func testCSVUsesAnIndependentRoute() async throws {
        let csv = "name,count\napples,2"

        let content = try await DocumentTextExtractionRouter().extract(
            data: Data(csv.utf8),
            filename: "inventory.csv",
            mimeType: "text/csv",
            format: .csv
        )

        XCTAssertEqual(content.sections.map(\.text), [csv])
    }

    func testRTFUsesTheRichTextRoute() async throws {
        let attributed = NSAttributedString(string: "Quarterly results")
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "results.rtf",
            mimeType: "application/rtf",
            format: .richText
        )

        XCTAssertEqual(content.sections.map(\.text), ["Quarterly results"])
    }

    func testWordDocumentsUseTheWordProcessingRoute() async throws {
        let attributed = NSAttributedString(string: "Project status")
        let formats: [(extension: String, type: NSAttributedString.DocumentType)] = [
            ("doc", .docFormat),
            ("docx", .officeOpenXML),
        ]

        for format in formats {
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: format.type]
            )
            let content = try await DocumentTextExtractionRouter().extract(
                data: data,
                filename: "status.\(format.extension)",
                mimeType: "application/octet-stream",
                format: .wordProcessing
            )

            XCTAssertEqual(content.sections.map(\.text), ["Project status"], format.extension)
        }
    }

    func testPPTXExtractsSlideTextInPresentationOrder() async throws {
        let data = try powerpointData(slides: [
            2: "Second slide",
            1: "First &amp; primary slide",
        ])

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "briefing.pptx",
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            format: .presentation
        )

        XCTAssertEqual(content.sourceSectionCount, 2)
        XCTAssertEqual(content.sections.map(\.location), [.slide(1), .slide(2)])
        XCTAssertEqual(content.sections.map(\.text), ["First & primary slide", "Second slide"])
    }

    func testPPTXRejectsInvalidArchives() async {
        do {
            _ = try await DocumentTextExtractionRouter().extract(
                data: Data("not a zip".utf8),
                filename: "broken.pptx",
                mimeType: "application/octet-stream",
                format: .presentation
            )
            XCTFail("Expected an invalid presentation error")
        } catch let error as DocumentTextExtractionError {
            XCTAssertEqual(error, .invalidDocument)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testODSExpandsRepeatedRowsAndCells() async throws {
        let data = try openDocumentData(content: """
            <office:document-content
                xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
              <office:body><office:spreadsheet><table:table>
                <table:table-row table:number-rows-repeated="2">
                  <table:table-cell table:number-columns-repeated="3"><text:p>test</text:p></table:table-cell>
                </table:table-row>
              </table:table></office:spreadsheet></office:body>
            </office:document-content>
            """)

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "repeated.ods",
            mimeType: "application/vnd.oasis.opendocument.spreadsheet",
            format: .openDocument
        )

        XCTAssertEqual(
            content.sections.map(\.text).joined(separator: "\n"),
            "test\ttest\ttest\ntest\ttest\ttest"
        )
    }

    func testODSUsesTypedValuesForTextlessCells() async throws {
        let data = try openDocumentData(content: """
            <office:document-content
                xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
              <office:body><office:spreadsheet><table:table>
                <table:table-row>
                  <table:table-cell office:value-type="float" office:value="42"/>
                  <table:table-cell office:value-type="date" office:date-value="2026-10-08"/>
                </table:table-row>
              </table:table></office:spreadsheet></office:body>
            </office:document-content>
            """)

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "values.ods",
            mimeType: "application/vnd.oasis.opendocument.spreadsheet",
            format: .openDocument
        )

        XCTAssertEqual(content.sections.map(\.text), ["42\t2026-10-08"])
    }

    func testXLSXRejectsCellReferencesBeyondTheExcelColumnLimit() async throws {
        let data = try spreadsheetData(rows: ["<row><c r=\"ZZZZZZ1\"><v>1</v></c></row>"])

        do {
            _ = try await DocumentTextExtractionRouter().extract(
                data: data,
                filename: "malformed.xlsx",
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                format: .spreadsheet
            )
            XCTFail("Expected an invalid document error")
        } catch {
            XCTAssertEqual(error as? DocumentTextExtractionError, .invalidDocument)
        }
    }

    func testXLSXAcceptsTheLastValidExcelColumn() async throws {
        let data = try spreadsheetData(rows: ["<row><c r=\"XFD1\"><v>1</v></c></row>"])

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "boundary.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            format: .spreadsheet
        )

        XCTAssertEqual(content.sections.first?.text.count, 16_384)
        XCTAssertTrue(content.sections.first?.text.hasSuffix("1") == true)
    }

    func testXLSXRejectsSparseOutputExpansionBeyondTheSafetyLimit() async throws {
        let rows = (1...1_024).map { "<row><c r=\"XFD\($0)\"><v>1</v></c></row>" }
        let data = try spreadsheetData(rows: rows)

        do {
            _ = try await DocumentTextExtractionRouter().extract(
                data: data,
                filename: "oversized.xlsx",
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                format: .spreadsheet
            )
            XCTFail("Expected an archive-too-large error")
        } catch {
            XCTAssertEqual(error as? DocumentTextExtractionError, .archiveTooLarge)
        }
    }

    private func powerpointData(slides: [Int: String]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create)
        for (number, text) in slides {
            let xml = Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                       xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                  <a:p><a:r><a:t>\(text)</a:t></a:r></a:p>
                </p:sld>
                """.utf8)
            try archive.addEntry(
                with: "ppt/slides/slide\(number).xml",
                type: .file,
                uncompressedSize: Int64(xml.count),
                provider: { position, size in
                    let start = Int(position)
                    return xml.subdata(in: start..<min(start + size, xml.count))
                }
            )
        }
        return try Data(contentsOf: url)
    }

    private func spreadsheetData(rows: [String]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create)
        let files = [
            "xl/workbook.xml": """
                <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <sheets><sheet name="Sheet1" r:id="rId1"/></sheets>
                </workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>
                """,
            "xl/worksheets/sheet1.xml": "<worksheet><sheetData>\(rows.joined())</sheetData></worksheet>",
        ]
        for (path, contents) in files {
            let data = Data(contents.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<min(start + size, data.count))
                }
            )
        }
        return try Data(contentsOf: url)
    }

    private func openDocumentData(content: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("ods")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create)
        let data = Data(content.utf8)
        try archive.addEntry(
            with: "content.xml",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        )
        return try Data(contentsOf: url)
    }
}
