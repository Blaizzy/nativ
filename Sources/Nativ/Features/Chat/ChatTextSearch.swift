import Foundation
import NaturalLanguage

enum ChatTextSearch {
    enum MatchKind: Int, Sendable {
        case exact
        case wordForm
        case typo
    }
 
    struct Match: Equatable, Sendable {
        let messageID: UUID
        let range: NSRange
        let kind: MatchKind
    }

    struct Message: Sendable {
        let id: UUID
        let text: String
        fileprivate let tokens: [Token]

        init(id: UUID, text: String, language: NLLanguage? = nil) throws {
            self.id = id
            self.text = text
            tokens = try tokenize(text, language: language)
        }
    }

    struct Query: Sendable {
        let text: String
        fileprivate let tokens: [Token]

        init(_ text: String, language: NLLanguage? = nil) throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = trimmed.count >= 2 && trimmed.first == "\"" && trimmed.last == "\""
            self.text = quoted ? String(trimmed.dropFirst().dropLast()) : trimmed
            let tokens = quoted ? [] : try tokenize(self.text, language: language)
            // Paths, identifiers with punctuation, and symbols keep literal search semantics.
            self.tokens = isWordPhrase(self.text, tokens: tokens) ? tokens : []
        }   
    }

    static func matches(in message: Message, query: Query, limit: Int = 200) throws -> [Match] {
        try Task.checkCancellation()
        guard limit > 0, !query.text.isEmpty else { return [] }
        var exact: [Range<String.Index>] = []
        var start = message.text.startIndex
        while start < message.text.endIndex, exact.count < limit {
            try Task.checkCancellation()
            guard let range = message.text.range(
                of: query.text,
                options: .caseInsensitive,
                range: start..<message.text.endIndex
            ) else { break }
            exact.append(range)
            start = range.upperBound
        }

        var occurrences = exact.map { ($0, MatchKind.exact) }
        if !query.tokens.isEmpty, message.tokens.count >= query.tokens.count {
            var decisions = Array(repeating: [Word: Decision](), count: query.tokens.count)
            var exactIndex = 0
            var variantCount = 0
            for index in 0...(message.tokens.count - query.tokens.count) {
                try Task.checkCancellation()
                let window = message.tokens[index..<(index + query.tokens.count)]
                guard let first = window.first, let last = window.last else { continue }
                let range = first.range.lowerBound..<last.range.upperBound
                if exact.count == limit, let lastExact = exact.last,
                   range.lowerBound >= lastExact.lowerBound { break }
                while exactIndex < exact.count, exact[exactIndex].upperBound <= range.lowerBound {
                    exactIndex += 1
                }
                if exactIndex < exact.count, exact[exactIndex].overlaps(range) { continue }
                var kind = MatchKind.exact
                var matched = true
                for (offset, token) in window.enumerated() {
                    let decision: Decision
                    if let cached = decisions[offset][token.word] {
                        decision = cached
                    } else {
                        decision = Decision(kind: match(token.word, query: query.tokens[offset].word))
                        decisions[offset][token.word] = decision
                    }
                    guard let tokenKind = decision.kind else {
                        matched = false
                        break
                    }
                    if tokenKind.rawValue > kind.rawValue { kind = tokenKind }
                }
                if matched, hasWhitespaceSeparators(message.text, tokens: window) {
                    occurrences.append((range, kind))
                    variantCount += 1
                    if variantCount == limit { break }
                }
            }
        }

        return occurrences.sorted { $0.0.lowerBound < $1.0.lowerBound }.prefix(limit).map {
            Match(messageID: message.id, range: NSRange($0.0, in: message.text), kind: $0.1)
        }
    }

    fileprivate struct Token: Sendable {
        let word: Word
        let range: Range<String.Index>
    }

    fileprivate struct Word: Hashable, Sendable {
        let text: String
        let lemma: String?
        let language: String?
        let allowsVariants: Bool
    }

    private struct Decision {
        let kind: MatchKind?
    }

    private static func tokenize(_ text: String, language: NLLanguage?) throws -> [Token] {
        try Task.checkCancellation()
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lemma, .language])
        tagger.string = text
        if let language { tagger.setLanguage(language, range: text.startIndex..<text.endIndex) }
        var tokens: [Token] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation, .omitOther]
        ) { lemma, range in
            guard !Task.isCancelled else { return false }
            let source = String(text[range])
            let tokenLanguage = language?.rawValue ?? tagger.tag(
                at: range.lowerBound, unit: .word, scheme: .language
            ).0?.rawValue
            tokens.append(Token(
                word: Word(
                    text: normalize(source),
                    lemma: lemma.map { normalize($0.rawValue) },
                    language: tokenLanguage,
                    allowsVariants: allowsVariants(source)
                ),
                range: range
            ))
            return true
        }
        try Task.checkCancellation()
        return tokens
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func allowsVariants(_ text: String) -> Bool {
        text.allSatisfy(\.isLetter) && !text.dropFirst().contains(where: \.isUppercase)
    }

    private static func isWordPhrase(_ text: String, tokens: [Token]) -> Bool {
        guard let first = tokens.first, let last = tokens.last,
              first.range.lowerBound == text.startIndex,
              last.range.upperBound == text.endIndex else { return false }
        return hasWhitespaceSeparators(text, tokens: tokens[...])
    }

    private static func hasWhitespaceSeparators(_ text: String, tokens: ArraySlice<Token>) -> Bool {
        for (left, right) in zip(tokens, tokens.dropFirst()) {
            let separator = text[left.range.upperBound..<right.range.lowerBound]
            guard !separator.isEmpty, separator.allSatisfy(\.isWhitespace) else { return false }
        }
        return true
    }

    private static func match(_ word: Word, query: Word) -> MatchKind? {
        if word.text == query.text { return .exact }
        guard word.allowsVariants, query.allowsVariants else { return nil }
        let sameLanguage = word.language != nil && word.language == query.language
        if sameLanguage, let lemma = word.lemma, lemma == query.lemma { return .wordForm }
        if isSpellingVariant(word.text, query.text) { return .typo }
        if sameLanguage {
            if let lemma = word.lemma, isSpellingVariant(lemma, query.text) { return .typo }
            if let lemma = query.lemma, isSpellingVariant(word.text, lemma) { return .typo }
        }
        return nil
    }

    private static func isSpellingVariant(_ lhs: String, _ rhs: String) -> Bool {
        let shorter = min(lhs.count, rhs.count)
        let longer = max(lhs.count, rhs.count)
        // Bound both false positives for short words and work for unusually long tokens.
        guard shorter >= 5, longer <= 64 else { return false }
        let limit = shorter >= 9 ? 2 : 1
        guard longer - shorter <= limit else { return false }
        return editDistance(Array(lhs), Array(rhs), limit: limit) <= limit
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character], limit: Int) -> Int {
        let outside = limit + 1
        var previous = Array(0...rhs.count)
        var beforePrevious = previous
        for row in 1...lhs.count {
            var current = Array(repeating: outside, count: rhs.count + 1)
            current[0] = row
            let lower = max(1, row - limit)
            let upper = min(rhs.count, row + limit)
            guard lower <= upper else { return outside }
            var minimum = outside
            for column in lower...upper {
                let replacement = previous[column - 1] + (lhs[row - 1] == rhs[column - 1] ? 0 : 1)
                current[column] = min(previous[column] + 1, current[column - 1] + 1, replacement)
                if row > 1, column > 1,
                   lhs[row - 1] == rhs[column - 2], lhs[row - 2] == rhs[column - 1] {
                    current[column] = min(current[column], beforePrevious[column - 2] + 1)
                }
                minimum = min(minimum, current[column])
            }
            if minimum > limit { return outside }
            beforePrevious = previous
            previous = current
        }
        return previous[rhs.count]
    }
}
