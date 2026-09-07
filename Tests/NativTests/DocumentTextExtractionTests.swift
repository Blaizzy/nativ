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
