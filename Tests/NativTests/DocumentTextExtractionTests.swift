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

    func testXLSXExtractsSheetsInWorkbookOrderAsTabSeparatedRows() async throws {
        let data = try archiveData(pathExtension: "xlsx", entries: [
            "xl/workbook.xml": """
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <sheets>
                    <sheet name="당첨번호" sheetId="1" r:id="rId2"/>
                    <sheet name="Empty" sheetId="2" r:id="rId3"/>
                    <sheet name="Notes" sheetId="3" r:id="rId1"/>
                  </sheets>
                </workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Target="worksheets/sheet3.xml"/>
                  <Relationship Id="rId2" Target="/xl/worksheets/sheet1.xml"/>
                  <Relationship Id="rId3" Target="worksheets/sheet2.xml"/>
                </Relationships>
                """,
            "xl/sharedStrings.xml": """
                <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <si><t>회차</t></si>
                  <si><t>번호1</t></si>
                  <si><r><t>Rich </t></r><r><t>&amp; text</t></r><rPh><t>ignored</t></rPh></si>
                </sst>
                """,
            "xl/worksheets/sheet1.xml": """
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <sheetData>
                    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
                    <row r="2"><c r="A2"><v>1140</v></c><c r="B2" t="b"><v>1</v></c><c r="C2"><f>1+2</f><v>3</v></c></row>
                    <row r="3"><c r="AA3" t="inlineStr"><is><t>far	cell</t></is></c></row>
                  </sheetData>
                </worksheet>
                """,
            "xl/worksheets/sheet2.xml": """
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <sheetData/>
                </worksheet>
                """,
            "xl/worksheets/sheet3.xml": """
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <sheetData><row r="1"><c r="A1" t="s"><v>2</v></c></row></sheetData>
                </worksheet>
                """,
        ])

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "lotto.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            format: .spreadsheet
        )

        XCTAssertEqual(content.sourceSectionCount, 3)
        XCTAssertEqual(content.sections.map(\.location), [.sheet("당첨번호"), .sheet("Notes")])
        XCTAssertEqual(content.sections.map(\.text), [
            "회차\t\t번호1\n1140\tTRUE\t3\n" + String(repeating: "\t", count: 26) + "far cell",
            "Rich & text",
        ])
        XCTAssertEqual(content.sectionName, "sheets")
    }

    func testXLSXFallsBackToWorksheetPartsWithoutWorkbook() async throws {
        let data = try archiveData(pathExtension: "xlsx", entries: [
            "xl/worksheets/sheet2.xml": """
                <worksheet><sheetData><row><c t="inlineStr"><is><t>second</t></is></c></row></sheetData></worksheet>
                """,
            "xl/worksheets/sheet1.xml": """
                <worksheet><sheetData><row><c><v>1</v></c><c><v>2</v></c></row></sheetData></worksheet>
                """,
        ])

        let content = try await DocumentTextExtractionRouter().extract(
            data: data,
            filename: "parts.xlsx",
            mimeType: "application/octet-stream",
            format: .spreadsheet
        )

        XCTAssertEqual(content.sections.map(\.location), [.sheet("Sheet1"), .sheet("Sheet2")])
        XCTAssertEqual(content.sections.map(\.text), ["1\t2", "second"])
    }

    func testXLSXRejectsInvalidArchives() async {
        do {
            _ = try await DocumentTextExtractionRouter().extract(
                data: Data("not a zip".utf8),
                filename: "broken.xlsx",
                mimeType: "application/octet-stream",
                format: .spreadsheet
            )
            XCTFail("Expected an invalid spreadsheet error")
        } catch let error as DocumentTextExtractionError {
            XCTAssertEqual(error, .invalidDocument)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func archiveData(pathExtension: String, entries: [String: String]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(pathExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in entries {
            let xml = Data(text.utf8)
            try archive.addEntry(
                with: path,
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
}
