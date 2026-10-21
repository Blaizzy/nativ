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

    func testXLSXCombinesInlineRichTextRunsInOneCell() async throws {
        let data = try spreadsheetData(rows: ["""
            <row><c r="A1" t="inlineStr"><is>
              <r><t>Hello </t></r><r><t>world</t></r>
            </is></c><c r="B1"><v>42</v></c></row>
            """])
        let content = try await SpreadsheetDocumentTextExtractor().extract(
            data: data, filename: "rich.xlsx", mimeType: "application/octet-stream"
        )
        XCTAssertEqual(content.text, "Hello world\t42")
    }

    func testXLSXEmptyCellsRetainTheirColumn() async throws {
        for row in [
            "<row><c t=\"inlineStr\"><is><t>A</t></is></c><c/><c><v>3</v></c></row>",
            "<row><c r=\"A1\" t=\"inlineStr\"><is><t>A</t></is></c><c r=\"B1\"/><c r=\"C1\"><v>3</v></c></row>",
        ] {
            let content = try await SpreadsheetDocumentTextExtractor().extract(
                data: spreadsheetData(rows: [row]),
                filename: "empty-cell.xlsx", mimeType: "application/octet-stream"
            )
            XCTAssertEqual(content.text, "A\t\t3")
        }
    }

    func testXLSXStopsBeforeExpandingAnOversizedSharedStringRow() async throws {
        let data = try spreadsheetData(
            rows: ["<row>" + String(repeating: "<c t=\"s\"><v>0</v></c>", count: 3) + "</row><malformed"],
            sharedStrings: [String(repeating: "x", count: 64)]
        )
        // The budget must stop parsing at the oversized cell, before the malformed tail.
        await assertArchiveTooLarge(data, filename: "repeated.xlsx", maximumOutputBytes: 128)
    }

    func testXLSXBoundsUTF8BytesAcrossSheets() async throws {
        let data = try spreadsheetData(
            rows: ["<row><c t=\"inlineStr\"><is><t>ééé</t></is></c></row>"],
            sheetCount: 2
        )
        await assertArchiveTooLarge(data, filename: "unicode.xlsx", maximumOutputBytes: 13)
        let content = try await SpreadsheetDocumentTextExtractor(maximumOutputBytes: 14).extract(
            data: data, filename: "unicode.xlsx", mimeType: "application/octet-stream"
        )
        XCTAssertEqual(content.sections.map(\.text), ["ééé", "ééé"])
    }

    func testODSStopsBeforeExpandingAnOversizedRepeatedCell() async throws {
        let data = try openDocumentData(content: """
            <root xmlns:table="urn:table" xmlns:text="urn:text">
              <table:table-row><table:table-cell table:number-columns-repeated="100">
                <text:p>test</text:p>
              </table:table-cell></table:table-row><malformed
            """)
        await assertArchiveTooLarge(data, filename: "repeated.ods", maximumOutputBytes: 128)
    }

    func testODSBoundsRepeatedRowsIncludingSeparators() async throws {
        let data = try openDocumentData(content: """
            <root xmlns:table="urn:table" xmlns:text="urn:text">
              <table:table-row table:number-rows-repeated="2">
                <table:table-cell><text:p>abc</text:p></table:table-cell>
              </table:table-row>
            </root>
            """)
        await assertArchiveTooLarge(data, filename: "rows.ods", maximumOutputBytes: 6)
        let content = try await OpenDocumentTextExtractor(maximumOutputBytes: 7).extract(
            data: data, filename: "rows.ods", mimeType: "application/octet-stream"
        )
        XCTAssertEqual(content.text, "abc\nabc")
    }

    func testODSBoundsCumulativeSpaceExpansionWithinACell() async throws {
        let data = try openDocumentData(content: """
            <root xmlns:table="urn:table" xmlns:text="urn:text">
              <table:table-row><table:table-cell>
                <text:p>x<text:s text:c="64"/><text:s text:c="65"/>y</text:p>
              </table:table-cell></table:table-row>
            </root>
            """)
        await assertArchiveTooLarge(data, filename: "spaces.ods", maximumOutputBytes: 128)
    }

    func testODSBudgetUsesUTF8Bytes() async throws {
        let data = try openDocumentData(content: """
            <root xmlns:table="urn:table" xmlns:text="urn:text">
              <table:table-row><table:table-cell><text:p>éé</text:p></table:table-cell></table:table-row>
            </root>
            """)
        await assertArchiveTooLarge(data, filename: "unicode.ods", maximumOutputBytes: 3)
        let content = try await OpenDocumentTextExtractor(maximumOutputBytes: 4).extract(
            data: data, filename: "unicode.ods", mimeType: "application/octet-stream"
        )
        XCTAssertEqual(content.text, "éé")
    }

    func testEPUBResolvesChapterURLsInReadingOrder() async throws {
        let chapters = [
            (href: "../Text/chapter%201.xhtml", path: "OPS/Text/chapter 1.xhtml", text: "First"),
            (href: "../Text/../Text/chapter%232.xhtml#section", path: "OPS/Text/chapter#2.xhtml", text: "Second"),
            (href: "../Text/%E6%97%A5%E6%9C%AC.xhtml", path: "OPS/Text/日本.xhtml", text: "Third"),
        ]
        let content = try await EPUBDocumentTextExtractor().extract(
            data: epubData(packagePath: "OPS/Package/content.opf", chapters: chapters),
            filename: "book.epub", mimeType: "application/epub+zip"
        )
        XCTAssertEqual(content.sections.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(content.sourceSectionCount, 3)
    }

    func testEPUBSupportsAPackageAtTheArchiveRoot() async throws {
        let content = try await EPUBDocumentTextExtractor().extract(
            data: epubData(
                packagePath: "content.opf",
                chapters: [(href: "./chapter.xhtml", path: "chapter.xhtml", text: "Chapter")]
            ),
            filename: "root.epub", mimeType: "application/epub+zip"
        )
        XCTAssertEqual(content.text, "Chapter")
    }

    func testEPUBRejectsExternalAndEscapingChapterURLs() async throws {
        for href in ["https://example.com/chapter.xhtml", "//example.com/chapter.xhtml", "../../../chapter.xhtml"] {
            let data = try epubData(
                packagePath: "OPS/Package/content.opf",
                chapters: [(href: href, path: "chapter.xhtml", text: "Outside")]
            )
            do {
                _ = try await EPUBDocumentTextExtractor().extract(
                    data: data, filename: "invalid.epub", mimeType: "application/epub+zip"
                )
                XCTFail("Expected an invalid document for \(href)")
            } catch {
                XCTAssertEqual(error as? DocumentTextExtractionError, .invalidDocument, href)
            }
        }
    }

    private func assertArchiveTooLarge(
        _ data: Data, filename: String, maximumOutputBytes: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let extractor: any DocumentTextExtracting = filename.hasSuffix(".xlsx")
            ? SpreadsheetDocumentTextExtractor(maximumOutputBytes: maximumOutputBytes)
            : OpenDocumentTextExtractor(maximumOutputBytes: maximumOutputBytes)
        do {
            _ = try await extractor.extract(
                data: data, filename: filename, mimeType: "application/octet-stream"
            )
            XCTFail("Expected the output budget to reject \(filename)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DocumentTextExtractionError, .archiveTooLarge, file: file, line: line)
        }
    }

    private func epubData(
        packagePath: String, chapters: [(href: String, path: String, text: String)]
    ) throws -> Data {
        var files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"\(packagePath)\"/></rootfiles></container>"
        ]
        let manifest = chapters.enumerated().map {
            "<item id=\"chapter\($0.offset)\" href=\"\($0.element.href)\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"chapter\($0)\"/>" }.joined()
        files[packagePath] = "<package><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        for chapter in chapters {
            files[chapter.path] = "<html><body><p>\(chapter.text)</p></body></html>"
        }
        return try archiveData(files: files)
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

    private func spreadsheetData(
        rows: [String], sharedStrings: [String] = [], sheetCount: Int = 1
    ) throws -> Data {
        let sheets = (1...sheetCount).map { "<sheet name=\"Sheet\($0)\" r:id=\"rId\($0)\"/>" }.joined()
        let relationships = (1...sheetCount).map {
            "<Relationship Id=\"rId\($0)\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        var files = [
            "xl/workbook.xml": """
                <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <sheets>\(sheets)</sheets>
                </workbook>
                """,
            "xl/_rels/workbook.xml.rels": "<Relationships>\(relationships)</Relationships>",
        ]
        for sheet in 1...sheetCount {
            files["xl/worksheets/sheet\(sheet).xml"] = "<worksheet><sheetData>\(rows.joined())</sheetData></worksheet>"
        }
        if !sharedStrings.isEmpty {
            files["xl/sharedStrings.xml"] = "<sst>" + sharedStrings.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
        }
        return try archiveData(files: files)
    }

    private func archiveData(files: [String: String]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create)
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
