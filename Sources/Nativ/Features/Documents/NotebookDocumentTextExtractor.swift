import Foundation

/// Extracts Jupyter notebook cells in order, one section per cell.
///
/// Image and other binary outputs are replaced with a placeholder: a notebook carrying a few
/// plots is mostly base64, which would otherwise reach the model as megabytes of noise.
actor NotebookDocumentTextExtractor: DocumentTextExtracting {
    nonisolated let formats: Set<ChatDocumentFormat> = [.notebook]

    static let maximumOutputCharacters = 2_000

    func extract(
        data: Data,
        filename: String,
        mimeType: String
    ) async throws -> ExtractedDocumentContent {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyData }

        let root: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DocumentTextExtractionError.invalidDocument
            }
            root = parsed
        } catch is DocumentTextExtractionError {
            throw DocumentTextExtractionError.invalidDocument
        } catch {
            throw DocumentTextExtractionError.invalidDocument
        }

        guard let cells = root["cells"] as? [[String: Any]] else {
            throw DocumentTextExtractionError.invalidDocument
        }

        var sections: [ExtractedDocumentSection] = []
        for (index, cell) in cells.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            let kind = (cell["cell_type"] as? String) ?? "code"
            var parts: [String] = []

            if let source = Self.joined(cell["source"]), !source.isEmpty {
                parts.append(source)
            }
            if let outputs = cell["outputs"] as? [[String: Any]] {
                let rendered = Self.render(outputs: outputs)
                if !rendered.isEmpty {
                    parts.append("[output]\n" + rendered)
                }
            }

            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sections.append(ExtractedDocumentSection(
                location: .named("Cell \(number) · \(kind)"),
                text: text
            ))
        }

        guard !sections.isEmpty else {
            throw DocumentTextExtractionError.noExtractableText
        }
        return ExtractedDocumentContent(
            filename: filename,
            mimeType: mimeType,
            sourceSectionCount: cells.count,
            sections: sections
        )
    }

    /// Notebook string fields are either a string or an array of lines.
    private static func joined(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let lines = value as? [String] { return lines.joined() }
        return nil
    }

    private static func render(outputs: [[String: Any]]) -> String {
        var rendered: [String] = []
        for output in outputs {
            switch output["output_type"] as? String {
            case "stream":
                if let text = joined(output["text"]) { rendered.append(text) }
            case "error":
                let name = output["ename"] as? String ?? "Error"
                let value = output["evalue"] as? String ?? ""
                rendered.append("\(name): \(value)")
            default:
                guard let bundle = output["data"] as? [String: Any] else { continue }
                if let text = joined(bundle["text/plain"]) {
                    rendered.append(text)
                } else if let type = bundle.keys.sorted().first {
                    rendered.append("[\(type) output omitted]")
                }
            }
        }

        let text = rendered
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard text.count > maximumOutputCharacters else { return text }
        return String(text.prefix(maximumOutputCharacters)) + "\n[output truncated]"
    }
}
