import Foundation
import ZIPFoundation

/// Extracts text from OpenDocument text and spreadsheet files, which both store their
/// content in a single `content.xml`.
actor OpenDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.openDocument]

    private static let contentLimit: UInt64 = 32 * 1_024 * 1_024
    private let maximumOutputBytes: Int

    init(maximumOutputBytes: Int = 16 * 1_024 * 1_024) {
        precondition(maximumOutputBytes > 0)
        self.maximumOutputBytes = maximumOutputBytes
    }

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
            ? OpenDocumentSpreadsheetParser(maximumOutputBytes: maximumOutputBytes)
            : ElementTextParser(
                textElements: ["p", "h", "span", "a", "list-item"],
                blockElements: ["p", "h", "list-item", "table-row"]
            )
        try XMLTextParsing.parse(content, with: delegate)
        let text: String
        if let spreadsheet = delegate as? OpenDocumentSpreadsheetParser {
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

private final class OpenDocumentSpreadsheetParser: NSObject, XMLTextParsingErrorReporting {
    private static let maximumColumnCount = 16_384
    private static let maximumExpandedRows = 100_000
    private static let textElements: Set<String> = ["p", "h", "span", "a", "list-item"]
    private static let valueAttributes = [
        "string-value", "value", "date-value", "time-value", "boolean-value",
    ]

    private let maximumOutputBytes: Int
    private var output = ""
    private var outputByteCount = 0
    private var cells: [String] = []
    private var rowByteCount = 0
    private var rowRepeat = 1
    private var cellText = ""
    private var cellByteCount = 0
    private var needsParagraphSeparator = false
    private var cellValue = ""
    private var cellRepeat = 1
    private var textDepth = 0
    private var isReadingCell = false
    private var expandedRowCount = 0
    private(set) var error: DocumentTextExtractionError?

    init(maximumOutputBytes: Int) {
        self.maximumOutputBytes = maximumOutputBytes
    }

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
            rowByteCount = 0
            rowRepeat = repeatCount(in: attributeDict, named: "number-rows-repeated", parser: parser)
        case "table-cell", "covered-table-cell":
            isReadingCell = true
            cellText = ""
            cellByteCount = 0
            needsParagraphSeparator = false
            cellValue = Self.value(in: attributeDict)
            cellRepeat = repeatCount(in: attributeDict, named: "number-columns-repeated", parser: parser)
            textDepth = 0
        case "s" where isReadingCell && textDepth > 0:
            let count = repeatCount(in: attributeDict, named: "c", parser: parser)
            guard error == nil else { return }
            guard count <= remainingRowBytes - cellByteCount - paragraphSeparatorBytes else {
                fail(.archiveTooLarge, parser: parser)
                return
            }
            appendCellText(String(repeating: " ", count: count), parser: parser)
        case "tab" where isReadingCell && textDepth > 0:
            appendCellText("\t", parser: parser)
        case "line-break" where isReadingCell && textDepth > 0:
            appendCellText("\n", parser: parser)
        default:
            if isReadingCell, Self.textElements.contains(name) { textDepth += 1 }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if error == nil, isReadingCell, textDepth > 0 { appendCellText(string, parser: parser) }
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
                needsParagraphSeparator = true
            }
        }
        guard error == nil else { return }

        switch name {
        case "table-cell", "covered-table-cell":
            let text = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cellRepeat <= Self.maximumColumnCount - cells.count else {
                fail(.archiveTooLarge, parser: parser)
                return
            }
            let value = text.isEmpty ? cellValue : text
            let separators = cells.isEmpty ? cellRepeat - 1 : cellRepeat
            let remaining = remainingRowBytes
            let valueBytes = value.utf8.count
            guard separators <= remaining,
                valueBytes <= (remaining - separators) / cellRepeat
            else {
                fail(.archiveTooLarge, parser: parser)
                return
            }
            rowByteCount += separators + valueBytes * cellRepeat
            cells.append(contentsOf: repeatElement(value, count: cellRepeat))
            isReadingCell = false
        case "table-row":
            while cells.last?.isEmpty == true {
                cells.removeLast()
                if !cells.isEmpty { rowByteCount -= 1 }
            }
            guard rowByteCount > 0 else { return }
            guard rowRepeat <= Self.maximumExpandedRows - expandedRowCount else {
                fail(.archiveTooLarge, parser: parser)
                return
            }
            let separators = output.isEmpty ? rowRepeat - 1 : rowRepeat
            let remaining = maximumOutputBytes - outputByteCount
            guard separators <= remaining,
                rowByteCount <= (remaining - separators) / rowRepeat
            else {
                fail(.archiveTooLarge, parser: parser)
                return
            }
            let row = cells.joined(separator: "\t")
            for _ in 0..<rowRepeat {
                if !output.isEmpty { output.append("\n") }
                output.append(row)
            }
            outputByteCount += separators + rowByteCount * rowRepeat
            expandedRowCount += rowRepeat
        default:
            break
        }
    }

    private var remainingRowBytes: Int {
        maximumOutputBytes - outputByteCount - rowByteCount
    }

    private func appendCellText(_ text: String, parser: XMLParser) {
        let count = text.utf8.count + paragraphSeparatorBytes
        guard count <= remainingRowBytes - cellByteCount else {
            fail(.archiveTooLarge, parser: parser)
            return
        }
        cellByteCount += count
        if paragraphSeparatorBytes > 0 { cellText.append("\n") }
        needsParagraphSeparator = false
        cellText.append(text)
    }

    private var paragraphSeparatorBytes: Int {
        needsParagraphSeparator && !cellText.isEmpty && !cellText.hasSuffix("\n") ? 1 : 0
    }

    private func fail(_ error: DocumentTextExtractionError, parser: XMLParser) {
        self.error = error
        parser.abortParsing()
    }

    private func repeatCount(
        in attributes: [String: String], named name: String, parser: XMLParser
    ) -> Int {
        guard let value = attributes.first(where: {
            XMLTextParsing.localName($0.key) == name
        })?.value else {
            return 1
        }
        guard let count = Int(value), count > 0 else {
            fail(.invalidDocument, parser: parser)
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
