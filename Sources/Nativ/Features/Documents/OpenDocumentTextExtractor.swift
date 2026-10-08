import Foundation
import ZIPFoundation

/// Extracts text from OpenDocument text and spreadsheet files, which both store their
/// content in a single `content.xml`.
actor OpenDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.openDocument]

    private static let contentLimit: UInt64 = 32 * 1_024 * 1_024

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }

        let archive = try OfficeArchive.open(data)
        guard let entry = archive["content.xml"] else {
            throw DocumentTextExtractionError.invalidDocument
        }
        let content = try OfficeArchive.data(for: entry, in: archive, limit: Self.contentLimit)

        let isSheet = (filename as NSString).pathExtension.lowercased() == "ods"
        let delegate: XMLParserDelegate = isSheet
            ? OpenDocumentSpreadsheetParser()
            : ElementTextParser(
                textElements: ["p", "h", "span", "a", "list-item"],
                blockElements: ["p", "h", "list-item", "table-row"]
            )
        try XMLTextParsing.parse(content, with: delegate)
        let text: String
        if let spreadsheet = delegate as? OpenDocumentSpreadsheetParser {
            if let error = spreadsheet.error { throw error }
            text = spreadsheet.text
        } else {
            text = (delegate as? ElementTextParser)?.text ?? ""
        }
        guard !text.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }

        return try TextDocumentContent.make(
            text: text,
            filename: filename,
            mimeType: mimeType
        )
    }
}

private final class OpenDocumentSpreadsheetParser: NSObject, XMLParserDelegate {
    private static let maximumColumnCount = 16_384
    private static let maximumExpandedRows = 100_000
    private static let maximumOutputCharacters = 16 * 1_024 * 1_024
    private static let textElements: Set<String> = ["p", "h", "span", "a", "list-item"]
    private static let valueAttributes = [
        "string-value", "value", "date-value", "time-value", "boolean-value",
    ]

    private var output = ""
    private var cells: [String] = []
    private var rowRepeat = 1
    private var cellText = ""
    private var cellValue = ""
    private var cellRepeat = 1
    private var textDepth = 0
    private var isReadingCell = false
    private var expandedRowCount = 0
    private(set) var error: DocumentTextExtractionError?

    var text: String { output }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard error == nil else { return }
        let name = XMLTextParsing.localName(elementName)
        switch name {
        case "table-row":
            cells = []
            rowRepeat = repeatCount(in: attributeDict, named: "number-rows-repeated")
        case "table-cell", "covered-table-cell":
            isReadingCell = true
            cellText = ""
            cellValue = Self.value(in: attributeDict)
            cellRepeat = repeatCount(in: attributeDict, named: "number-columns-repeated")
            textDepth = 0
        case "s" where isReadingCell && textDepth > 0:
            let count = repeatCount(in: attributeDict, named: "c")
            guard count <= Self.maximumOutputCharacters else {
                error = .archiveTooLarge
                return
            }
            cellText.append(String(repeating: " ", count: count))
        case "tab" where isReadingCell && textDepth > 0:
            cellText.append("\t")
        case "line-break" where isReadingCell && textDepth > 0:
            cellText.append("\n")
        default:
            if isReadingCell, Self.textElements.contains(name) { textDepth += 1 }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if error == nil, isReadingCell, textDepth > 0 { cellText.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard error == nil else { return }
        let name = XMLTextParsing.localName(elementName)
        if isReadingCell, Self.textElements.contains(name), textDepth > 0 {
            textDepth -= 1
            if ["p", "h", "list-item"].contains(name), !cellText.hasSuffix("\n") {
                cellText.append("\n")
            }
        }

        switch name {
        case "table-cell", "covered-table-cell":
            let text = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cellRepeat <= Self.maximumColumnCount - cells.count else {
                error = .archiveTooLarge
                return
            }
            cells.append(contentsOf: repeatElement(text.isEmpty ? cellValue : text, count: cellRepeat))
            isReadingCell = false
        case "table-row":
            while cells.last?.isEmpty == true { cells.removeLast() }
            let row = cells.joined(separator: "\t")
            guard !row.isEmpty else { return }
            guard rowRepeat <= Self.maximumExpandedRows - expandedRowCount else {
                error = .archiveTooLarge
                return
            }
            let separators = output.isEmpty ? rowRepeat - 1 : rowRepeat
            let remainingCharacters = Self.maximumOutputCharacters - output.count
            guard separators <= remainingCharacters,
                row.count <= (remainingCharacters - separators) / rowRepeat
            else {
                error = .archiveTooLarge
                return
            }
            for _ in 0..<rowRepeat {
                if !output.isEmpty { output.append("\n") }
                output.append(row)
            }
            expandedRowCount += rowRepeat
        default:
            break
        }
    }

    private func repeatCount(in attributes: [String: String], named name: String) -> Int {
        guard let value = attributes.first(where: {
            XMLTextParsing.localName($0.key) == name
        })?.value else {
            return 1
        }
        guard let count = Int(value), count > 0 else {
            error = .invalidDocument
            return 1
        }
        return count
    }

    private static func value(in attributes: [String: String]) -> String {
        for name in valueAttributes {
            if let value = attributes.first(where: {
                XMLTextParsing.localName($0.key) == name
            })?.value {
                return value
            }
        }
        return ""
    }
}
