import Foundation

@MainActor
final class HuggingFaceModelReadmeStore: ObservableObject {
    @Published private(set) var modelID: String?
    @Published private(set) var markdown: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let client = HuggingFaceModelReadmeClient()
    private var cache: [String: String] = [:]

    func load(repoID: String, localSnapshotURL: URL?, token: String?) async {
        modelID = repoID
        error = nil

        if let cached = cache[repoID] {
            markdown = cached
            isLoading = false
            return
        }

        markdown = nil
        isLoading = true
        do {
            let markdown = try await client.readme(
                repoID: repoID,
                localSnapshotURL: localSnapshotURL,
                token: token
            )
            try Task.checkCancellation()
            guard modelID == repoID else { return }
            cache[repoID] = markdown
            self.markdown = markdown
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard modelID == repoID else { return }
            markdown = nil
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        guard modelID == repoID else { return }
        isLoading = false
    }

    func clearSelection() {
        modelID = nil
        markdown = nil
        isLoading = false
        error = nil
    }
}

enum HuggingFaceModelReadmeError: LocalizedError, Equatable {
    case invalidRepositoryID
    case notFound
    case authenticationRequired
    case invalidResponse
    case requestFailed(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID:
            "This model doesn’t have a Hugging Face repository."
        case .notFound:
            "This model doesn’t include a README."
        case .authenticationRequired:
            "Sign in to Hugging Face to view this model’s README."
        case .invalidResponse:
            "Hugging Face returned an invalid README response."
        case .requestFailed(let statusCode):
            "The model README couldn’t be loaded (HTTP \(statusCode))."
        case .empty:
            "This model’s README is empty."
        }
    }
}

struct HuggingFaceModelReadmeClient: Sendable {
    func readme(
        repoID: String,
        localSnapshotURL: URL?,
        token: String?
    ) async throws -> String {
        if let localSnapshotURL,
           let localReadme = try await localReadme(in: localSnapshotURL)
        {
            return try preparedMarkdown(from: localReadme)
        }

        let pathComponents = repoID.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count == 2 else {
            throw HuggingFaceModelReadmeError.invalidRepositoryID
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoID)/raw/main/README.md"
        guard let url = components.url else {
            throw HuggingFaceModelReadmeError.invalidRepositoryID
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/markdown, text/plain", forHTTPHeaderField: "Accept")
        request.setValue("Nativ/1.0", forHTTPHeaderField: "User-Agent")
        HuggingFaceAuthentication.authorize(&request, token: token)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HuggingFaceModelReadmeError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return try preparedMarkdown(from: String(decoding: data, as: UTF8.self))
        case 401, 403:
            throw HuggingFaceModelReadmeError.authenticationRequired
        case 404:
            throw HuggingFaceModelReadmeError.notFound
        default:
            throw HuggingFaceModelReadmeError.requestFailed(httpResponse.statusCode)
        }
    }

    private func localReadme(in snapshotURL: URL) async throws -> String? {
        let candidates = ["README.md", "README.MD", "readme.md"]
            .map { snapshotURL.appendingPathComponent($0, isDirectory: false) }
        guard let readmeURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return nil
        }

        return try await Task.detached(priority: .utility) {
            try String(contentsOf: readmeURL, encoding: .utf8)
        }.value
    }

    private func preparedMarkdown(from markdown: String) throws -> String {
        let prepared = HuggingFaceModelReadmeFormatting.displayMarkdown(markdown)
        guard !prepared.isEmpty else {
            throw HuggingFaceModelReadmeError.empty
        }
        return prepared
    }
}

enum HuggingFaceModelReadmeFormatting {
    static func displayMarkdown(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let closingIndex = lines.dropFirst().firstIndex(where: {
               let line = $0.trimmingCharacters(in: .whitespaces)
               return line == "---" || line == "..."
           })
        {
            lines.removeSubrange(lines.startIndex...closingIndex)
        }

        return normalizeHTMLOutsideCodeFences(lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingDuplicateLeadingTitle(_ markdown: String, modelTitle: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let headingIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return markdown
        }

        let candidate = lines[headingIndex].trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("#") else { return markdown }
        let heading = candidate.drop(while: { $0 == "#" || $0.isWhitespace })
        guard normalizedTitle(String(heading)) == normalizedTitle(modelTitle) else {
            return markdown
        }

        lines.remove(at: headingIndex)
        while headingIndex < lines.endIndex,
              lines[headingIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.remove(at: headingIndex)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : nil
        }.map(String.init).joined()
    }

    /// Hugging Face model cards frequently use small HTML fragments for centered banners,
    /// navigation links, and inline emphasis. Textual intentionally renders Markdown rather
    /// than arbitrary HTML, so translate the safe presentation subset instead of exposing tags.
    private static func normalizeHTMLOutsideCodeFences(_ markdown: String) -> String {
        var result = ""
        var prose = ""
        var fence: String?

        func flushProse() {
            guard !prose.isEmpty else { return }
            result += normalizeHTMLFragment(prose)
            prose = ""
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let delimiter: String? = trimmed.hasPrefix("```") ? "```"
                : (trimmed.hasPrefix("~~~") ? "~~~" : nil)

            if let delimiter {
                if fence == nil {
                    flushProse()
                    fence = delimiter
                } else if fence == delimiter {
                    fence = nil
                }
                result += text + "\n"
            } else if fence == nil {
                prose += text + "\n"
            } else {
                result += text + "\n"
            }
        }
        flushProse()
        return result
    }

    private static func normalizeHTMLFragment(_ markdown: String) -> String {
        var output = markdown
        output = replacingMatches(in: output, pattern: "<table\\b[^>]*>(.*?)</table\\s*>") {
            match, source in
            markdownTable(from: capture(1, from: match, source: source))
        }
        output = replacingMatches(in: output, pattern: "<!--.*?-->") { _, _ in "" }
        output = replacingMatches(in: output, pattern: "<(script|style|svg)\\b[^>]*>.*?</\\1\\s*>") {
            _, _ in ""
        }
        output = replacingMatches(in: output, pattern: "<img\\b[^>]*>") { match, source in
            let tag = source.substring(with: match.range)
            guard let sourceURL = htmlAttribute("src", in: tag), !sourceURL.isEmpty else {
                return ""
            }
            let alt = htmlAttribute("alt", in: tag) ?? ""
            return "![\(decodeHTMLEntities(alt))](\(decodeHTMLEntities(sourceURL)))"
        }
        output = replacingMatches(in: output, pattern: "<a\\b([^>]*)>(.*?)</a\\s*>") {
            match, source in
            let attributes = capture(1, from: match, source: source)
            let label = capture(2, from: match, source: source)
                .replacingOccurrences(
                    of: "</?(span|font|b|strong|i|em)\\b[^>]*>",
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = htmlAttribute("href", in: attributes), !url.isEmpty else {
                return label
            }
            return "[\(decodeHTMLEntities(label))](\(decodeHTMLEntities(url)))"
        }

        for level in 1...6 {
            output = replacingMatches(
                in: output,
                pattern: "<h\(level)\\b[^>]*>(.*?)</h\(level)\\s*>"
            ) { match, source in
                let title = capture(1, from: match, source: source)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "\n\n\(String(repeating: "#", count: level)) \(title)\n\n"
            }
        }

        let literalReplacements: [(String, String)] = [
            ("<br\\s*/?>", "  \n"),
            ("<hr\\s*/?>", "\n\n---\n\n"),
            ("<(b|strong)\\b[^>]*>", "**"),
            ("</(b|strong)\\s*>", "**"),
            ("<(i|em)\\b[^>]*>", "*"),
            ("</(i|em)\\s*>", "*"),
            ("<code\\b[^>]*>", "`"),
            ("</code\\s*>", "`"),
            ("<li\\b[^>]*>", "\n- "),
            ("</li\\s*>", ""),
            ("<summary\\b[^>]*>", "\n\n### "),
            ("</summary\\s*>", "\n\n"),
            ("<(div|p|center|section|figure|figcaption|details|ul|ol|table|thead|tbody|tr|blockquote)\\b[^>]*>", "\n\n"),
            ("</(div|p|center|section|figure|figcaption|details|ul|ol|table|thead|tbody|tr|blockquote)\\s*>", "\n\n"),
            ("<(td|th)\\b[^>]*>", " | "),
            ("</(td|th)\\s*>", " | "),
            ("</?(span|font|picture|source|sup|sub|kbd|u)\\b[^>]*>", ""),
        ]
        for (pattern, replacement) in literalReplacements {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        output = decodeHTMLEntities(output)
        return output
            // HTML model cards commonly indent links inside centered paragraphs.
            // Once converted to Markdown, four leading spaces turn those links
            // into code blocks instead of interactive links.
            .replacingOccurrences(
                of: "(?m)^[ \\t]+(?=(?:!?\\[|\\*\\*|#{1,6}[ \\t]))",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n(?:[ \\t]*\\n){2,}", with: "\n\n", options: .regularExpression)
    }

    private struct HTMLTableCell {
        let text: String
        let isHeader: Bool
    }

    /// Foundation parses GitHub-style Markdown tables but not raw HTML tables.
    /// Translate complete rows before the general HTML cleanup so model-card
    /// comparisons retain their columns and can scroll horizontally.
    private static func markdownTable(from html: String) -> String {
        guard let rowExpression = try? NSRegularExpression(
            pattern: "<tr\\b[^>]*>(.*?)</tr\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let cellExpression = try? NSRegularExpression(
            pattern: "<(th|td)\\b([^>]*)>(.*?)</\\1\\s*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ""
        }

        let source = html as NSString
        let rowMatches = rowExpression.matches(
            in: html,
            range: NSRange(location: 0, length: source.length)
        )
        var rows: [[HTMLTableCell]] = []
        var columnCount = 0

        for rowMatch in rowMatches {
            let rowHTML = capture(1, from: rowMatch, source: source)
            let rowSource = rowHTML as NSString
            let cellMatches = cellExpression.matches(
                in: rowHTML,
                range: NSRange(location: 0, length: rowSource.length)
            )
            var cells: [HTMLTableCell] = []

            for cellMatch in cellMatches {
                let tagName = capture(1, from: cellMatch, source: rowSource).lowercased()
                let attributes = capture(2, from: cellMatch, source: rowSource)
                let cellHTML = capture(3, from: cellMatch, source: rowSource)
                let colspan = max(Int(htmlAttribute("colspan", in: attributes) ?? "") ?? 1, 1)
                cells.append(
                    HTMLTableCell(
                        text: normalizedHTMLTableCell(cellHTML),
                        isHeader: tagName == "th"
                    )
                )
                cells.append(
                    contentsOf: repeatElement(
                        HTMLTableCell(text: "", isHeader: false),
                        count: colspan - 1
                    )
                )
            }

            guard !cells.isEmpty else { continue }
            columnCount = max(columnCount, cells.count)
            rows.append(cells)
        }

        guard !rows.isEmpty, columnCount > 0 else { return "" }
        let emptyCell = HTMLTableCell(text: "", isHeader: false)
        rows = rows.map { row in
            row + Array(repeating: emptyCell, count: columnCount - row.count)
        }

        func markdownRow(_ row: [HTMLTableCell], isFirstRow: Bool = false) -> String {
            let values = row.map { cell -> String in
                guard !isFirstRow, cell.isHeader, !cell.text.isEmpty else {
                    return cell.text
                }
                return "**\(cell.text)**"
            }
            return "| \(values.joined(separator: " | ")) |"
        }

        var markdownRows = [markdownRow(rows[0], isFirstRow: true)]
        markdownRows.append(
            "| \(Array(repeating: "---", count: columnCount).joined(separator: " | ")) |"
        )
        markdownRows.append(contentsOf: rows.dropFirst().map { markdownRow($0) })
        return "\n\n\(markdownRows.joined(separator: "\n"))\n\n"
    }

    private static func normalizedHTMLTableCell(_ html: String) -> String {
        normalizeHTMLFragment(html)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "(?<!\\\\)\\|",
                with: "\\\\|",
                options: .regularExpression
            )
    }

    private static func replacingMatches(
        in input: String,
        pattern: String,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return input
        }
        let source = input as NSString
        let matches = expression.matches(
            in: input,
            range: NSRange(location: 0, length: source.length)
        )
        var output = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: transform(match, source))
        }
        return output
    }

    private static func capture(
        _ index: Int,
        from match: NSTextCheckingResult,
        source: NSString
    ) -> String {
        guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else {
            return ""
        }
        return source.substring(with: match.range(at: index))
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: "\\b\(escapedName)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
            options: .caseInsensitive
        ) else {
            return nil
        }
        let source = tag as NSString
        guard let match = expression.firstMatch(
            in: tag,
            range: NSRange(location: 0, length: source.length)
        ) else {
            return nil
        }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return source.substring(with: match.range(at: index))
        }
        return nil
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var output = text
        let named = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        ]
        for (entity, value) in named {
            output = output.replacingOccurrences(of: entity, with: value)
        }
        return replacingMatches(in: output, pattern: "&#(x?[0-9a-f]+);") { match, source in
            let value = capture(1, from: match, source: source)
            let radix = value.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(value.dropFirst()) : value
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue)
            else {
                return source.substring(with: match.range)
            }
            return String(Character(scalar))
        }
    }
}
