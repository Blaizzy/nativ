import Foundation
import ZIPFoundation

/// Extracts visible text from modern PowerPoint slide XML. Legacy `.ppt` is unsupported.
actor PowerPointDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.presentation]

    private static let slideLimit: UInt64 = 4 * 1_024 * 1_024

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }
        guard (filename as NSString).pathExtension.lowercased() == "pptx" else {
            throw DocumentTextExtractionError.unsupportedFormat
        }

        let archive = try OfficeArchive.open(data)

        var slideEntries: [(number: Int, entry: Entry)] = []
        for entry in archive {
            if let number = Self.slideNumber(for: entry.path) {
                guard entry.uncompressedSize <= Self.slideLimit else {
                    throw DocumentTextExtractionError.archiveTooLarge
                }
                slideEntries.append((number, entry))
            }
        }
        guard !slideEntries.isEmpty else {
            throw DocumentTextExtractionError.invalidDocument
        }

        var sections: [ExtractedDocumentSection] = []
        for slide in slideEntries.sorted(by: { $0.number < $1.number }) {
            try Task.checkCancellation()
            guard let text = try Self.text(for: slide.entry, in: archive) else { continue }
            sections.append(ExtractedDocumentSection(
                location: .slide(slide.number),
                text: text
            ))
        }
        guard !sections.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: slideEntries.count,
            sections: sections
        )
    }

    private static func slideNumber(for path: String) -> Int? {
        let prefix = "ppt/slides/slide"
        let suffix = ".xml"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        return Int(path.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func text(for entry: Entry, in archive: Archive) throws -> String? {
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                guard chunk.count <= Int(slideLimit) - data.count else {
                    throw DocumentTextExtractionError.archiveTooLarge
                }
                data.append(chunk)
            }
        } catch let error as DocumentTextExtractionError {
            throw error
        } catch {
            throw DocumentTextExtractionError.invalidDocument
        }

        let delegate = SlideTextParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw DocumentTextExtractionError.invalidDocument }
        return delegate.text.nilIfEmpty
    }
}

private final class SlideTextParser: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var paragraph = ""
    private var readsText = false

    var text: String {
        (paragraphs + [paragraph])
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
        switch Self.localName(elementName) {
        case "t": readsText = true
        case "br": paragraph.append("\n")
        case "tab": paragraph.append("\t")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readsText { paragraph.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.localName(elementName) {
        case "t":
            readsText = false
        case "p":
            if let text = paragraph.nilIfEmpty { paragraphs.append(text) }
            paragraph = ""
        default:
            break
        }
    }

    private static func localName(_ name: String) -> Substring {
        name.split(separator: ":").last ?? Substring(name)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
