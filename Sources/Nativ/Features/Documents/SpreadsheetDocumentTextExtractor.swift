import Foundation
import ZIPFoundation

/// Extracts cell values from modern Excel workbooks as tab-separated rows, one section per sheet.
/// Values are the stored cell values: formulas yield their cached result and dates stay serial numbers.
/// Legacy `.xls` is unsupported.
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

        let sharedStrings: [String]
        if let entry = archive["xl/sharedStrings.xml"] {
            let parser = SharedStringsParser()
            try Self.parse(entry, in: archive, with: parser)
            sharedStrings = parser.strings
        } else {
            sharedStrings = []
        }

        var sections: [ExtractedDocumentSection] = []
        for sheet in sheets {
            try Task.checkCancellation()
            guard let entry = archive[sheet.path] else { continue }
            let parser = WorksheetParser(sharedStrings: sharedStrings)
            try Self.parse(entry, in: archive, with: parser)
            guard let text = parser.text else { continue }
            sections.append(ExtractedDocumentSection(location: .sheet(sheet.name), text: text))
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

    /// Sheets in workbook order, falling back to worksheet part order when the workbook is incomplete.
    private static func sheets(in archive: Archive) throws -> [(name: String, path: String)] {
        if let workbookEntry = archive["xl/workbook.xml"],
            let relationshipsEntry = archive["xl/_rels/workbook.xml.rels"]
        {
            let workbook = WorkbookParser()
            try parse(workbookEntry, in: archive, with: workbook)
            let relationships = RelationshipsParser()
            try parse(relationshipsEntry, in: archive, with: relationships)
            let sheets = workbook.sheets.compactMap { sheet -> (name: String, path: String)? in
                guard let target = relationships.targets[sheet.relationshipID] else { return nil }
                return (sheet.name, partPath(forTarget: target))
            }
            if !sheets.isEmpty { return sheets }
        }

        let prefix = "xl/worksheets/sheet"
        let suffix = ".xml"
        return archive.compactMap { entry -> (number: Int, path: String)? in
            guard entry.path.hasPrefix(prefix), entry.path.hasSuffix(suffix),
                let number = Int(entry.path.dropFirst(prefix.count).dropLast(suffix.count))
            else { return nil }
            return (number, entry.path)
        }
        .sorted { $0.number < $1.number }
        .map { ("Sheet\($0.number)", $0.path) }
    }

    private static func partPath(forTarget target: String) -> String {
        target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
    }

    private static func parse(
        _ entry: Entry,
        in archive: Archive,
        with delegate: some XMLParserDelegate
    ) throws {
        guard entry.uncompressedSize <= partLimit else {
            throw DocumentTextExtractionError.archiveTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                guard chunk.count <= Int(partLimit) - data.count else {
                    throw DocumentTextExtractionError.archiveTooLarge
                }
                data.append(chunk)
            }
        } catch let error as DocumentTextExtractionError {
            throw error
        } catch {
            throw DocumentTextExtractionError.invalidDocument
        }

        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw DocumentTextExtractionError.invalidDocument }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [(name: String, relationshipID: String)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "sheet",
            let name = attributeDict["name"],
            let relationshipID = attributeDict.first(where: { localName($0.key) == "id" })?.value
        else { return }
        sheets.append((name, relationshipID))
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    private(set) var targets: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "Relationship",
            let id = attributeDict["Id"],
            let target = attributeDict["Target"]
        else { return }
        targets[id] = target
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = ""
    private var readsText = false
    private var phoneticDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "si": current = ""
        case "rPh": phoneticDepth += 1
        case "t": readsText = phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readsText { current.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "si": strings.append(current)
        case "rPh": phoneticDepth -= 1
        case "t": readsText = false
        default: break
        }
    }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [String] = []
    private var row: [Int: String] = [:]
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType: String?
    private var cellValue = ""
    private var readsValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    var text: String? {
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "row":
            row = [:]
            nextColumn = 0
        case "c":
            cellColumn = attributeDict["r"].flatMap(Self.columnIndex) ?? nextColumn
            cellType = attributeDict["t"]
            cellValue = ""
        case "v":
            readsValue = true
        case "t":
            readsValue = cellType == "inlineStr"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readsValue { cellValue.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "v", "t":
            readsValue = false
        case "c":
            if let value = resolvedValue(), !value.isEmpty {
                row[cellColumn] = value
            }
            nextColumn = cellColumn + 1
        case "row":
            guard let lastColumn = row.keys.max() else {
                rows.append("")
                return
            }
            rows.append((0...lastColumn).map { row[$0] ?? "" }.joined(separator: "\t"))
        default:
            break
        }
    }

    private func resolvedValue() -> String? {
        let value: String
        switch cellType {
        case "s":
            guard let index = Int(cellValue), sharedStrings.indices.contains(index) else {
                return nil
            }
            value = sharedStrings[index]
        case "b":
            value = cellValue == "1" ? "TRUE" : "FALSE"
        default:
            value = cellValue
        }
        return value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// Converts the column letters of a reference such as `AB12` into a zero-based index.
    private static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard ("A"..."Z").contains(scalar) else { break }
            index = index * 26 + Int(scalar.value - 64)
            sawLetter = true
        }
        return sawLetter ? index - 1 : nil
    }
}

private func localName(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
}
