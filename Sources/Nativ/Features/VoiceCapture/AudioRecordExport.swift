import AppKit
import CoreText
import UniformTypeIdentifiers

enum AudioRecordExportFormat: String, CaseIterable, Sendable {
    case pdf
    case docx
    case text = "txt"

    var title: String {
        rawValue.uppercased()
    }

    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .docx: UTType(filenameExtension: "docx") ?? .data
        case .text: .utf8PlainText
        }
    }
}

/// A snapshot of the saved content, independent of playback and later regeneration.
struct AudioRecordExport: Sendable {
    let record: AudioTranscriptionRecord

    var isAvailable: Bool {
        record.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 50

    enum ExportError: LocalizedError {
        case unavailableContent
        case pdfGenerationFailed

        var errorDescription: String? {
            switch self {
            case .unavailableContent: "Generate a summary and transcript before exporting this recording."
            case .pdfGenerationFailed: "The PDF could not be created. Try exporting as Word or plain text."
            }
        }
    }

    func filename(for format: AudioRecordExportFormat) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        var title = record.displayTitle.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Leave space for the content suffix and extension, including multibyte titles.
        while title.utf8.count > 160 { title.removeLast() }
        if title.isEmpty { title = "Recording" }
        return "\(title) - Summary and Transcript.\(format.rawValue)"
    }

    func write(to url: URL, format: AudioRecordExportFormat) throws {
        try data(format: format).write(to: url, options: .atomic)
    }

    func data(format: AudioRecordExportFormat) throws -> Data {
        guard isAvailable else { throw ExportError.unavailableContent }
        if format == .text {
            // Keep the saved summary markup and verbatim transcript in the editable text export.
            let sections = sections.map { "\($0.title)\n\n\($0.text)" }
            return Data(([record.displayTitle, metadata] + sections).joined(separator: "\n\n").utf8)
        }

        let document = attributedDocument()
        switch format {
        case .pdf:
            return try pdfData(document)
        case .docx:
            return try document.data(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.officeOpenXML,
                    .paperSize: Self.pageSize,
                    .leftMargin: Self.margin, .rightMargin: Self.margin,
                    .topMargin: Self.margin, .bottomMargin: Self.margin,
                ])
        case .text:
            preconditionFailure("Plain text is handled before document formatting")
        }
    }

    private var metadata: String {
        "Recorded \(record.recordedAt.formatted(date: .long, time: .shortened))"
    }

    private var sections: [(title: String, text: String, markdown: Bool)] {
        [
            ("Summary", record.summary ?? "", true),
            ("Transcript", record.transcript, false),
        ]
    }

    private func attributedDocument() -> NSAttributedString {
        let document = NSMutableAttributedString(string: "")
        document.append(Self.text(record.displayTitle + "\n", size: 22, bold: true))
        document.append(Self.text(metadata + "\n\n", size: 10))
        for section in sections {
            document.append(Self.text(section.title + "\n", size: 16, bold: true))
            if section.markdown {
                Self.append(MarkdownParser.parse(section.text), to: document)
            } else {
                document.append(Self.text(section.text + "\n"))
            }
            document.append(Self.text("\n"))
        }
        return document
    }

    private static func text(_ value: String, size: CGFloat = 11, bold: Bool = false)
        -> NSAttributedString
    {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        let font = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
        ])
    }

    private static func append(
        _ nodes: [MarkdownNode], to result: NSMutableAttributedString, indent: Int = 0
    ) {
        for node in nodes {
            switch node.kind {
            case "list":
                for (index, item) in node.children.enumerated() {
                    let marker = item.checked.map { $0 ? "☑" : "☐" }
                        ?? (node.ordered ? "\(node.start + index)." : "•")
                    result.append(text(String(repeating: "    ", count: indent) + marker + " "))
                    append(item.children, to: result, indent: indent + 1)
                }
            case "block_quote":
                append(node.children, to: result, indent: indent)
            case "table":
                for row in node.children {
                    for (index, cell) in row.children.enumerated() {
                        if index > 0 { result.append(text("  |  ")) }
                        result.append(inline(cell.children))
                    }
                    result.append(text("\n"))
                }
            case "thematic_break":
                result.append(text("—\n"))
            case "code_block":
                let code = NSMutableAttributedString(attributedString: text(node.literal + "\n"))
                code.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                  range: NSRange(location: 0, length: code.length))
                result.append(code)
            default:
                let size: CGFloat = node.kind == "heading" ? max(12, 18 - CGFloat(node.level)) : 11
                let value = node.children.isEmpty
                    ? text(node.literal, size: size, bold: node.kind == "heading")
                    : inline(node.children, size: size, bold: node.kind == "heading")
                result.append(value)
                result.append(text("\n"))
            }
        }
    }

    private static func inline(_ nodes: [MarkdownNode], size: CGFloat = 11, bold: Bool = false)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(string: "")
        for node in nodes {
            let value: NSMutableAttributedString
            switch node.kind {
            case "softbreak", "linebreak":
                value = NSMutableAttributedString(attributedString: text(node.kind == "softbreak" ? " " : "\n"))
            default:
                value = NSMutableAttributedString(attributedString: node.children.isEmpty
                    ? text(node.literal, size: size, bold: bold)
                    : inline(node.children, size: size, bold: bold || node.kind == "strong"))
            }
            let range = NSRange(location: 0, length: value.length)
            if node.kind == "emph" {
                value.enumerateAttribute(.font, in: range) { font, range, _ in
                    guard let font = font as? NSFont else { return }
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(.italic))
                    if let italic = NSFont(descriptor: descriptor, size: font.pointSize) {
                        value.addAttribute(.font, value: italic, range: range)
                    }
                }
            } else if node.kind == "code" {
                value.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: range)
            } else if node.kind == "strikethrough" {
                value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else if node.kind == "link", let url = URL(string: node.destination) {
                value.addAttribute(.link, value: url, range: range)
                // Core Text and Word converters may omit link annotations; retain the destination.
                if value.string != node.destination {
                    value.append(text(" (\(node.destination))", size: size))
                }
            } else if node.kind == "image", value.length == 0 {
                value.append(text(node.destination))
            }
            result.append(value)
        }
        return result
    }

    private func pdfData(_ document: NSAttributedString) throws -> Data {
        let data = NSMutableData()
        var page = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &page, [
                kCGPDFContextTitle: record.displayTitle,
                kCGPDFContextCreator: "Nativ",
              ] as CFDictionary)
        else { throw ExportError.pdfGenerationFailed }
        let framesetter = CTFramesetterCreateWithAttributedString(document)
        let path = CGPath(rect: page.insetBy(dx: Self.margin, dy: Self.margin), transform: nil)
        var offset = 0
        var pageNumber = 1
        while offset < document.length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.closePDF()
                throw ExportError.pdfGenerationFailed
            }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            let footer = CTLineCreateWithAttributedString(Self.text("\(pageNumber)", size: 9))
            context.textPosition = CGPoint(x: page.midX, y: 25)
            CTLineDraw(footer, context)
            context.endPDFPage()
            offset += visible.length
            pageNumber += 1
        }
        // Finalize the PDF before copying the mutable data.
        context.closePDF()
        return data as Data
    }
}
