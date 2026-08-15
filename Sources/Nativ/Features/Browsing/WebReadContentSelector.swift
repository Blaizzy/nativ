import Foundation

struct WebReadContentSelection: Equatable {
    let content: String
    let truncated: Bool
}

enum WebReadContentSelector {
    private struct Chunk {
        let index: Int
        let heading: String?
        let body: String

        var searchableText: String {
            [heading, body].compactMap { $0 }.joined(separator: "\n")
        }

        var maximumRenderedLength: Int {
            searchableText.count
        }
    }

    private static let maximumChunkCharacters = 1_200
    private static let omissionMarker = "[content omitted]"
    private static let stopWords: Set<String> = [
        "about", "after", "also", "and", "are", "but", "for", "from", "has", "have",
        "how", "into", "its", "not", "that", "the", "their", "then", "this", "use",
        "was", "were", "what", "when", "where", "which", "who", "why", "will", "with",
    ]

    static func select(_ content: String, focus: String?, limit: Int) -> WebReadContentSelection {
        guard content.count > limit else {
            return WebReadContentSelection(content: content, truncated: false)
        }
        guard limit > omissionMarker.count else {
            return WebReadContentSelection(content: String(content.prefix(limit)), truncated: true)
        }

        if let focus = normalizedFocus(focus),
           let excerpt = focusedExcerpt(content, focus: focus, limit: limit) {
            return WebReadContentSelection(content: excerpt, truncated: true)
        }
        return WebReadContentSelection(content: balancedExcerpt(content, limit: limit), truncated: true)
    }

    private static func focusedExcerpt(
        _ content: String,
        focus: String,
        limit: Int
    ) -> String? {
        let focusTerms = Set(tokens(in: focus))
        guard !focusTerms.isEmpty else { return nil }

        let chunks = chunks(from: content)
        let ranked = chunks.compactMap { chunk -> (chunk: Chunk, score: Int)? in
            let bodyTerms = tokens(in: chunk.body)
            let headingTerms = chunk.heading.map { tokens(in: $0) } ?? []
            let bodyMatches = bodyTerms.filter(focusTerms.contains)
            let uniqueMatches = Set(bodyMatches)
            let headingMatches = Set(headingTerms).intersection(focusTerms)
            guard !uniqueMatches.isEmpty || !headingMatches.isEmpty else { return nil }

            let phraseBonus = chunk.searchableText.localizedCaseInsensitiveContains(focus) ? 200 : 0
            let score = phraseBonus
                + uniqueMatches.count * 40
                + min(bodyMatches.count, 8) * 4
                + headingMatches.count * 60
            return (chunk, score)
        }.sorted {
            $0.score == $1.score
                ? $0.chunk.index < $1.chunk.index
                : $0.score > $1.score
        }
        guard !ranked.isEmpty else { return nil }

        var priority: [Int] = []
        for match in ranked {
            priority.append(match.chunk.index)
            for distance in 1 ... 2 {
                priority.append(match.chunk.index - distance)
                priority.append(match.chunk.index + distance)
            }
        }

        let byIndex = Dictionary(uniqueKeysWithValues: chunks.map { ($0.index, $0) })
        var selected = Set<Int>()
        var estimatedLength = 0
        for index in priority where !selected.contains(index) {
            guard let chunk = byIndex[index] else { continue }
            let separatorLength = selected.isEmpty ? 0 : omissionMarker.count + 4
            guard estimatedLength + separatorLength + chunk.maximumRenderedLength <= limit else {
                continue
            }
            selected.insert(index)
            estimatedLength += separatorLength + chunk.maximumRenderedLength
        }
        guard !selected.isEmpty else { return nil }

        return render(chunks.filter { selected.contains($0.index) }, limit: limit)
    }

    private static func render(_ chunks: [Chunk], limit: Int) -> String {
        var output = ""
        var previousIndex: Int?
        var previousHeading: String?

        for chunk in chunks {
            let hasGap = previousIndex.map { chunk.index != $0 + 1 } ?? false
            if hasGap {
                append("\n\n\(omissionMarker)\n\n", to: &output, limit: limit)
                previousHeading = nil
            } else if !output.isEmpty {
                append("\n\n", to: &output, limit: limit)
            }

            if let heading = chunk.heading, heading != previousHeading {
                append("\(heading)\n", to: &output, limit: limit)
                previousHeading = heading
            }
            append(chunk.body, to: &output, limit: limit)
            previousIndex = chunk.index
            guard output.count < limit else { break }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ value: String, to output: inout String, limit: Int) {
        let remaining = limit - output.count
        guard remaining > 0 else { return }
        output += String(value.prefix(remaining))
    }

    private static func chunks(from content: String) -> [Chunk] {
        let blocks = content.components(separatedBy: "\n\n")
        var chunks: [Chunk] = []
        var heading: String?

        for rawBlock in blocks {
            let block = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !block.isEmpty else { continue }

            let lines = block.components(separatedBy: .newlines)
            var bodyLines = lines
            if let first = lines.first, isHeading(first) {
                heading = String(first.prefix(300))
                bodyLines.removeFirst()
            }
            let body = bodyLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            for piece in split(body, maximumLength: maximumChunkCharacters) {
                chunks.append(Chunk(index: chunks.count, heading: heading, body: piece))
            }
        }
        return chunks
    }

    private static func split(_ value: String, maximumLength: Int) -> [String] {
        var remainder = value[...]
        var pieces: [String] = []

        while remainder.count > maximumLength {
            let proposedEnd = remainder.index(remainder.startIndex, offsetBy: maximumLength)
            let candidate = remainder[..<proposedEnd]
            let minimumBreak = candidate.index(candidate.startIndex, offsetBy: maximumLength / 2)
            let breakIndex = candidate[minimumBreak...].lastIndex(where: { $0 == "\n" || $0 == "." })
                .map { candidate.index(after: $0) }
                ?? proposedEnd
            pieces.append(String(remainder[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
            remainder = remainder[breakIndex...].drop(while: { $0.isWhitespace })
        }
        if !remainder.isEmpty {
            pieces.append(String(remainder).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return pieces.filter { !$0.isEmpty }
    }

    private static func balancedExcerpt(_ content: String, limit: Int) -> String {
        let available = limit - omissionMarker.count - 4
        let headLength = available * 2 / 3
        let tailLength = available - headLength
        let head = String(content.prefix(headLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(content.suffix(tailLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(head)\n\n\(omissionMarker)\n\n\(tail)"
    }

    private static func normalizedFocus(_ focus: String?) -> String? {
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        return focus?.isEmpty == false ? focus : nil
    }

    private static func tokens(in value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    private static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return false }
        let title = trimmed.drop(while: { $0 == "#" })
        return title.first?.isWhitespace == true
    }
}
