import Foundation
import ZIPFoundation

/// Extracts an EPUB's chapters in reading order, one section per spine item.
actor EPUBDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.ebook]

    private static let partLimit: UInt64 = 16 * 1_024 * 1_024

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }

        let archive = try OfficeArchive.open(data)
        let packagePath = try Self.packagePath(in: archive)
        guard let packageEntry = archive[packagePath] else {
            throw DocumentTextExtractionError.invalidDocument
        }
        let packageData = try OfficeArchive.data(for: 
            packageEntry, in: archive, limit: Self.partLimit
        )
        let package = PackageParser()
        try XMLTextParsing.parse(packageData, with: package)

        let base = (packagePath as NSString).deletingLastPathComponent
        let documents = package.spine.compactMap { package.manifest[$0] }
        guard !documents.isEmpty else {
            throw DocumentTextExtractionError.invalidDocument
        }

        var sections: [ExtractedDocumentSection] = []
        for (index, relativePath) in documents.enumerated() {
            try Task.checkCancellation()
            let path = base.isEmpty
                ? relativePath
                : (base as NSString).appendingPathComponent(relativePath)
            guard let entry = archive[path] ?? archive[relativePath] else { continue }
            let chapter = try OfficeArchive.data(for: entry, in: archive, limit: Self.partLimit)
            let delegate = ElementTextParser(
                textElements: ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "span", "a", "td"],
                blockElements: ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "div", "tr"]
            )
            try XMLTextParsing.parse(chapter, with: delegate)
            let text = delegate.text
            guard !text.isEmpty else { continue }
            sections.append(ExtractedDocumentSection(
                location: .named("Chapter \(index + 1)"),
                text: text
            ))
        }

        guard !sections.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: documents.count,
            sections: sections
        )
    }

    private static func packagePath(in archive: Archive) throws -> String {
        guard let container = archive["META-INF/container.xml"] else {
            throw DocumentTextExtractionError.invalidDocument
        }
        let data = try OfficeArchive.data(for: container, in: archive, limit: partLimit)
        let delegate = ContainerParser()
        try XMLTextParsing.parse(data, with: delegate)
        guard let path = delegate.packagePath else {
            throw DocumentTextExtractionError.invalidDocument
        }
        return path
    }
}

private final class ContainerParser: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard packagePath == nil,
            XMLTextParsing.localName(elementName) == "rootfile",
            let path = attributeDict["full-path"]
        else { return }
        packagePath = path
    }
}

private final class PackageParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch XMLTextParsing.localName(elementName) {
        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else { return }
            let type = attributeDict["media-type"] ?? ""
            let fileExtension = (href as NSString).pathExtension.lowercased()
            if type.contains("html") || ["xhtml", "html", "htm"].contains(fileExtension) {
                manifest[id] = href
            }
        case "itemref":
            if let id = attributeDict["idref"] { spine.append(id) }
        default:
            break
        }
    }
}
