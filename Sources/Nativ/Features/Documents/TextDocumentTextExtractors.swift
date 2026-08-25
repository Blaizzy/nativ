import AppKit
import Foundation

struct PlainTextDocumentTextExtractor: DocumentTextExtracting {
    let formats: Set<ChatDocumentFormat> = [.plainText]

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        return try TextDocumentContent.make(data: data, filename: filename, mimeType: mimeType)
    }
}

struct CSVDocumentTextExtractor: DocumentTextExtracting {
    let formats: Set<ChatDocumentFormat> = [.csv]

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        return try TextDocumentContent.make(data: data, filename: filename, mimeType: mimeType)
    }
}

/// AppKit document readers are confined because their Sendability is not guaranteed.
actor RichTextDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.richText, .wordProcessing]

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }

        let fileExtension = filename.pathExtension
        if fileExtension == "docx" { _ = try OfficeArchive.open(data) }
        let documentType: NSAttributedString.DocumentType = switch fileExtension {
        case "rtf": .rtf
        case "doc": .docFormat
        case "docx": .officeOpenXML
        default: throw DocumentTextExtractionError.unsupportedFormat
        }
        let text: String
        do {
            text = try NSAttributedString(
                data: data,
                options: [.documentType: documentType],
                documentAttributes: nil
            ).string
        } catch {
            throw DocumentTextExtractionError.invalidDocument
        }
        return try TextDocumentContent.make(
            text: text.trimmingCharacters(in: .newlines),
            filename: filename,
            mimeType: mimeType
        )
    }
}

private enum TextDocumentContent {
    private static let sectionLimit = 4_000

    static func make(
        data: Data,
        filename: String,
        mimeType: String
    ) throws -> ExtractedDocumentContent {
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }
        guard let text = decodedText(data) else {
            throw DocumentTextExtractionError.invalidDocument
        }
        return try make(text: text, filename: filename, mimeType: mimeType)
    }

    static func make(
        text: String,
        filename: String,
        mimeType: String
    ) throws -> ExtractedDocumentContent {
        let normalized = text
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
        guard normalized.contains(where: { !$0.isWhitespace }) else {
            throw DocumentTextExtractionError.noExtractableText
        }

        let sections = sections(in: normalized)
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: sections.count,
            sections: sections
        )
    }

    private static func decodedText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf32, .windowsCP1252, .isoLatin1,
        ]
        return encodings.lazy.compactMap { encoding in
            guard let text = String(data: data, encoding: encoding), !text.contains("\0") else {
                return nil
            }
            return text
        }.first
    }

    private static func sections(in text: String) -> [ExtractedDocumentSection] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [ExtractedDocumentSection] = []
        var buffer: [Substring] = []
        var characterCount = 0
        var firstLine = 1

        func flush(through lastLine: Int) {
            guard !buffer.isEmpty else { return }
            result.append(ExtractedDocumentSection(
                location: .lines(firstLine, lastLine),
                text: buffer.joined(separator: "\n")
            ))
            buffer.removeAll(keepingCapacity: true)
            characterCount = 0
        }

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            if line.count > sectionLimit {
                flush(through: lineNumber - 1)
                for chunk in line.chunks(ofCount: sectionLimit) {
                    result.append(ExtractedDocumentSection(
                        location: .lines(lineNumber, lineNumber),
                        text: String(chunk)
                    ))
                }
                firstLine = lineNumber + 1
                continue
            }

            if !buffer.isEmpty, characterCount + line.count + 1 > sectionLimit {
                flush(through: lineNumber - 1)
            }
            if buffer.isEmpty { firstLine = lineNumber }
            characterCount += line.count + (buffer.isEmpty ? 0 : 1)
            buffer.append(line)
        }
        flush(through: lines.count)
        return result
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension.lowercased()
    }
}

private extension Substring {
    func chunks(ofCount count: Int) -> [Substring] {
        var chunks: [Substring] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: count, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }
}
