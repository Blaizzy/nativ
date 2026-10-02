import Foundation

enum XMLTextParsing {
    /// Parses with external entities disabled, which must hold for every document we open.
    static func parse(_ data: Data, with delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw DocumentTextExtractionError.invalidDocument }
    }

    static func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }
}

/// Collects character data from the elements named in `textElements`, breaking a
/// paragraph whenever one of `blockElements` closes and inserting a tab whenever one of
/// `separatorElements` closes, which keeps spreadsheet cells apart within a row.
final class ElementTextParser: NSObject, XMLParserDelegate {
    private let textElements: Set<String>
    private let blockElements: Set<String>
    private let separatorElements: Set<String>
    private var paragraphs: [String] = []
    private var paragraph = ""
    private var depth = 0

    init(
        textElements: Set<String>,
        blockElements: Set<String>,
        separatorElements: Set<String> = []
    ) {
        self.textElements = textElements
        self.blockElements = blockElements
        self.separatorElements = separatorElements
    }

    var text: String {
        (paragraphs + [paragraph])
            .map {
                $0.hasSuffix("\t") ? String($0.dropLast()) : $0
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if textElements.contains(XMLTextParsing.localName(elementName)) { depth += 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth > 0 { paragraph.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = XMLTextParsing.localName(elementName)
        if textElements.contains(name), depth > 0 { depth -= 1 }
        if blockElements.contains(name) {
            paragraphs.append(paragraph)
            paragraph = ""
        } else if separatorElements.contains(name) {
            paragraph.append("\t")
        }
    }
}
