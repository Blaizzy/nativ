import Foundation
import ZIPFoundation

enum ArchiveEntryData {
    static func read(_ entry: Entry, in archive: Archive, limit: UInt64) throws -> Data {
        guard entry.uncompressedSize <= limit else {
            throw DocumentTextExtractionError.archiveTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                guard chunk.count <= Int(limit) - data.count else {
                    throw DocumentTextExtractionError.archiveTooLarge
                }
                data.append(chunk)
            }
        } catch let error as DocumentTextExtractionError {
            throw error
        } catch {
            throw DocumentTextExtractionError.invalidDocument
        }
        return data
    }

    static func parse(_ data: Data, with delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw DocumentTextExtractionError.invalidDocument }
    }
}

/// Collects character data from the elements named in `textElements`, breaking a
/// paragraph whenever one of `blockElements` closes.
final class ElementTextParser: NSObject, XMLParserDelegate {
    private let textElements: Set<String>
    private let blockElements: Set<String>
    private var paragraphs: [String] = []
    private var paragraph = ""
    private var depth = 0

    init(textElements: Set<String>, blockElements: Set<String>) {
        self.textElements = textElements
        self.blockElements = blockElements
    }

    var text: String {
        (paragraphs + [paragraph])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func localName(_ elementName: String) -> String {
        elementName.split(separator: ":").last.map(String.init) ?? elementName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if textElements.contains(Self.localName(elementName)) { depth += 1 }
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
        let name = Self.localName(elementName)
        if textElements.contains(name), depth > 0 { depth -= 1 }
        if blockElements.contains(name) {
            paragraphs.append(paragraph)
            paragraph = ""
        }
    }
}
