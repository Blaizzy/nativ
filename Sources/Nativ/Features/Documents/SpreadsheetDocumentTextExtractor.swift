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
            try XMLTextParsing.parse(
                OfficeArchive.data(for: entry, in: archive, limit: Self.partLimit),
                with: parser
            )
            sharedStrings = parser.strings
        }

        var sections: [ExtractedDocumentSection] = []
        for sheet in sheets {
            try Task.checkCancellation()
            guard let entry = archive[sheet.path] else { continue }
            let parser = WorksheetParser(sharedStrings: sharedStrings)
            try XMLTextParsing.parse(
                OfficeArchive.data(for: entry, in: archive, limit: Self.partLimit),
                with: parser
            )
            if let error = parser.error { throw error }
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
            try XMLTextParsing.parse(
                OfficeArchive.data(for: workbookEntry, in: archive, limit: partLimit),
                with: workbook
            )
            let relationships = RelationshipsParser()
            try XMLTextParsing.parse(
                OfficeArchive.data(for: relationshipsEntry, in: archive, limit: partLimit),
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
        guard XMLTextParsing.localName(elementName) == "sheet",
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
        guard XMLTextParsing.localName(elementName) == "Relationship",
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
        if XMLTextParsing.localName(elementName) == "si" { current = "" }
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
        guard XMLTextParsing.localName(elementName) == "si" else { return }
        strings.append(current ?? "")
        current = nil
    }
}

/// Emits one tab-separated line per row, preserving column gaps so columns stay aligned.
private final class WorksheetParser: NSObject, XMLParserDelegate {
    private static let maximumColumnCount = 16_384
    private static let maximumOutputCharacters = 16 * 1_024 * 1_024

    private let sharedStrings: [String]
    private var rows: [String] = []
    private var outputCharacterCount = 0
    private var cells: [String] = []
    private var value = ""
    private var readsValue = false
    private var isSharedString = false
    private(set) var error: DocumentTextExtractionError?

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
        guard error == nil else { return }
        switch XMLTextParsing.localName(elementName) {
        case "row":
            cells = []
        case "c":
            isSharedString = (attributeDict["t"] ?? "") == "s"
            if let reference = attributeDict["r"] {
                guard let target = Self.column(for: reference) else {
                    error = .invalidDocument
                    return
                }
                while cells.count < target { cells.append("") }
            }
        case "v", "t":
            readsValue = true
            value = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if error == nil, readsValue { value.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard error == nil else { return }
        switch XMLTextParsing.localName(elementName) {
        case "v", "t":
            guard readsValue else { return }
            readsValue = false
            if isSharedString, let index = Int(value), sharedStrings.indices.contains(index) {
                cells.append(sharedStrings[index])
            } else {
                cells.append(value)
            }
        case "row":
            while let last = cells.last, last.isEmpty { cells.removeLast() }
            let row = cells.joined(separator: "\t")
            let separatorCount = rows.isEmpty ? 0 : 1
            guard outputCharacterCount + separatorCount + row.count
                    <= Self.maximumOutputCharacters
            else {
                error = .archiveTooLarge
                return
            }
            rows.append(row)
            outputCharacterCount += separatorCount + row.count
        default:
            break
        }
    }

    /// Zero-based column index from a cell reference such as `BC12`.
    private static func column(for reference: String) -> Int? {
        var index = 0
        var letterCount = 0
        var hasRow = false
        for character in reference {
            guard let ascii = character.asciiValue else { return nil }
            if ascii >= 48, ascii <= 57 {
                guard letterCount > 0 else { return nil }
                hasRow = true
                continue
            }
            guard !hasRow, ascii >= 65, ascii <= 90, letterCount < 3 else { return nil }
            index = index * 26 + Int(ascii - 64)
            letterCount += 1
        }
        guard hasRow, index <= maximumColumnCount else { return nil }
        return index - 1
    }
}
