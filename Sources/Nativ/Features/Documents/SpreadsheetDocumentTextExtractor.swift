import Foundation
import ZIPFoundation

/// Extracts cell values from modern Excel workbooks as tab-separated rows, one section per sheet.
///
/// Values are the stored ones: a formula yields its cached result and a date stays a serial
/// number. Legacy `.xls` is a different binary format and stays unsupported.
actor SpreadsheetDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.spreadsheet]

    private static let partLimit: UInt64 = 64 * 1_024 * 1_024

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }
        guard (filename as NSString).pathExtension.lowercased() == "xlsx" else {
            throw DocumentTextExtractionError.unsupportedFormat
        }

        let archive = try OfficeArchive.open(data)
        let sheets = try Self.sheets(in: archive)
        guard !sheets.isEmpty else { throw DocumentTextExtractionError.invalidDocument }

        var sharedStrings: [String] = []
        if let entry = archive["xl/sharedStrings.xml"] {
            let parser = SharedStringsParser()
            try ArchiveEntryData.parse(
                ArchiveEntryData.read(entry, in: archive, limit: Self.partLimit),
                with: parser
            )
            sharedStrings = parser.strings
        }

        var sections: [ExtractedDocumentSection] = []
        for sheet in sheets {
            try Task.checkCancellation()
            guard let entry = archive[sheet.path] else { continue }
            let parser = WorksheetParser(sharedStrings: sharedStrings)
            try ArchiveEntryData.parse(
                ArchiveEntryData.read(entry, in: archive, limit: Self.partLimit),
                with: parser
            )
            let text = parser.text
            guard !text.isEmpty else { continue }
            sections.append(ExtractedDocumentSection(
                location: .named("Sheet \(sheet.name)"),
                text: text
            ))
        }
        guard !sections.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: sheets.count,
            sections: sections
        )
    }

    /// Sheets in workbook order, falling back to worksheet part order when the workbook
    /// relationships are missing.
    private static func sheets(in archive: Archive) throws -> [(name: String, path: String)] {
        if let workbookEntry = archive["xl/workbook.xml"],
            let relationshipsEntry = archive["xl/_rels/workbook.xml.rels"] {
            let workbook = WorkbookParser()
            try ArchiveEntryData.parse(
                ArchiveEntryData.read(workbookEntry, in: archive, limit: partLimit),
                with: workbook
            )
            let relationships = RelationshipsParser()
            try ArchiveEntryData.parse(
                ArchiveEntryData.read(relationshipsEntry, in: archive, limit: partLimit),
                with: relationships
            )
            let sheets = workbook.sheets.compactMap { sheet -> (name: String, path: String)? in
                guard let target = relationships.targets[sheet.relationshipID] else { return nil }
                let path = target.hasPrefix("/")
                    ? String(target.dropFirst())
                    : "xl/" + target
                return (sheet.name, path)
            }
            if !sheets.isEmpty { return sheets }
        }

        return archive
            .map(\.path)
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
            .enumerated()
            .map { (name: "\($0.offset + 1)", path: $0.element) }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relationshipID: String)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard ElementTextParser.localName(elementName) == "sheet",
            let name = attributeDict["name"],
            let id = attributeDict["r:id"] ?? attributeDict["id"]
        else { return }
        sheets.append((name, id))
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard ElementTextParser.localName(elementName) == "Relationship",
            let id = attributeDict["Id"],
            let target = attributeDict["Target"]
        else { return }
        targets[id] = target
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if ElementTextParser.localName(elementName) == "si" { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { current?.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard ElementTextParser.localName(elementName) == "si" else { return }
        strings.append(current ?? "")
        current = nil
    }
}

/// Emits one tab-separated line per row, preserving column gaps so columns stay aligned.
private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [String] = []
    private var cells: [String] = []
    private var value = ""
    private var readsValue = false
    private var isSharedString = false
    private var isInlineString = false
    private var columnIndex = 0

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    var text: String {
        rows.joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch ElementTextParser.localName(elementName) {
        case "row":
            cells = []
            columnIndex = 0
        case "c":
            let type = attributeDict["t"] ?? ""
            isSharedString = type == "s"
            isInlineString = type == "inlineStr"
            if let reference = attributeDict["r"] {
                let target = Self.column(for: reference)
                while columnIndex < target {
                    cells.append("")
                    columnIndex += 1
                }
            }
        case "v", "t":
            readsValue = true
            value = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readsValue { value.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch ElementTextParser.localName(elementName) {
        case "v", "t":
            guard readsValue else { return }
            readsValue = false
            if isSharedString, let index = Int(value), sharedStrings.indices.contains(index) {
                cells.append(sharedStrings[index])
            } else if !value.isEmpty || isInlineString {
                cells.append(value)
            }
            columnIndex += 1
        case "row":
            while let last = cells.last, last.isEmpty { cells.removeLast() }
            rows.append(cells.joined(separator: "\t"))
        default:
            break
        }
    }

    /// Zero-based column index from a cell reference such as `BC12`.
    private static func column(for reference: String) -> Int {
        var index = 0
        for character in reference {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }
}
