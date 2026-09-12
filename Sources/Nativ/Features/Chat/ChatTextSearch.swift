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

    struct Message: Codable, Sendable {
        let id: UUID
        let text: String
        fileprivate let tokens: [Token]
        fileprivate let fragments: Set<UInt64>

        var language: NLLanguage? {
            tokens.first?.word.language.map { NLLanguage(rawValue: $0) }
        }

        var isSingleWord: Bool { tokens.count == 1 }

        init(id: UUID, text: String, language: NLLanguage? = nil) throws {
            self.id = id
            self.text = text
            tokens = try tokenize(text, language: language)
            fragments = Index<Int>.fragments(text)
        }

        private struct StoredToken: Codable {
            let word: Word
            let range: NSRange
        }

        private enum CodingKeys: CodingKey { case id, text, tokens, fragments }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            text = try values.decode(String.self, forKey: .text)
            fragments = try values.decode(Set<UInt64>.self, forKey: .fragments)
            let source = text
            tokens = try values.decode([StoredToken].self, forKey: .tokens).map { token in
                guard let range = Range(token.range, in: source) else {
                    throw DecodingError.dataCorruptedError(forKey: .tokens, in: values,
                                                           debugDescription: "Invalid token range")
                }
                return Token(word: token.word, range: range)
            }
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(text, forKey: .text)
            try values.encode(fragments, forKey: .fragments)
            try values.encode(tokens.map { StoredToken(word: $0.word, range: NSRange($0.range, in: text)) },
                              forKey: .tokens)
        }
    }

    struct Query: Sendable {
        let text: String
        fileprivate let tokens: [Token]

        var language: NLLanguage? {
            tokens.first?.word.language.map { NLLanguage(rawValue: $0) }
        }

        init(_ text: String, languageCode: String) throws {
            try self.init(text, language: languageCode.isEmpty ? nil : NLLanguage(rawValue: languageCode))
        }

        init(_ text: String, language: NLLanguage? = nil) throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = trimmed.count >= 2 && trimmed.first == "\"" && trimmed.last == "\""
            self.text = quoted ? String(trimmed.dropFirst().dropLast()) : trimmed
            let tokens = quoted ? [] : try tokenize(self.text, language: language)
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

    struct Index<ID: Hashable & Sendable>: Sendable {
        private var fragments: [UInt64: Set<ID>] = [:]
        private var words: [Word: Set<ID>] = [:]
        private var spellings: [String: Set<Word>] = [:]
        private var pairs: [String: [String: Int]] = [:]

        mutating func insert(_ message: Message, id: ID) {
            for fragment in message.fragments {
                fragments[fragment, default: []].insert(id)
            }
            for word in Set(message.tokens.map(\.word)) {
                if words[word] == nil {
                    for spelling in Set([word.text, word.lemma].compactMap { $0 }) {
                        if spellings[spelling] == nil {
                            for (pair, count) in Self.pairs(spelling) {
                                pairs[pair, default: [:]][spelling] = count
                            }
                        }
                        spellings[spelling, default: []].insert(word)
                    }
                }
                words[word, default: []].insert(id)
            }
        }

        mutating func remove(_ message: Message, id: ID) {
            for fragment in message.fragments {
                fragments[fragment]?.remove(id)
                if fragments[fragment]?.isEmpty == true { fragments[fragment] = nil }
            }
            for word in Set(message.tokens.map(\.word)) {
                words[word]?.remove(id)
                guard words[word]?.isEmpty == true else { continue }
                words[word] = nil
                for spelling in Set([word.text, word.lemma].compactMap { $0 }) {
                    spellings[spelling]?.remove(word)
                    guard spellings[spelling]?.isEmpty == true else { continue }
                    spellings[spelling] = nil
                    for pair in Self.pairs(spelling).keys {
                        pairs[pair]?[spelling] = nil
                        if pairs[pair]?.isEmpty == true { pairs[pair] = nil }
                    }
                }
            }
        }

        func candidates(for query: Query) throws -> Set<ID> {
            try Task.checkCancellation()
            guard !query.text.isEmpty else { return [] }
            let grams = Self.fragments(query.text, longestOnly: true)
            let ordered = grams.sorted { (fragments[$0]?.count ?? 0) < (fragments[$1]?.count ?? 0) }
            var result = ordered.first.flatMap { fragments[$0] } ?? []
            for gram in ordered.dropFirst() {
                if result.isEmpty { break }
                try Task.checkCancellation()
                result.formIntersection(fragments[gram] ?? [])
            }
            var phrase: Set<ID>?
            for token in query.tokens {
                let candidates = try candidates(for: token.word)
                if phrase == nil { phrase = candidates }
                else { phrase?.formIntersection(candidates) }
                if phrase?.isEmpty == true { break }
            }
            if let phrase { result.formUnion(phrase) }
            return result
        }

        private func candidates(for query: Word) throws -> Set<ID> {
            var candidates = spellings[query.text] ?? []
            if query.allowsVariants {
                for text in Set([query.text, query.lemma].compactMap { $0 }) {
                    candidates.formUnion(spellings[text] ?? [])
                    let length = text.count
                    guard (5...64).contains(length) else { continue }
                    let distance = length >= 9 ? 2 : 1
                    let threshold = length - 1 - 3 * distance
                    var overlap: [String: Int] = [:]
                    for (pair, count) in Self.pairs(text) {
                        try Task.checkCancellation()
                        for (spelling, frequency) in pairs[pair] ?? [:] {
                            overlap[spelling, default: 0] += min(count, frequency)
                        }
                    }
                    for (spelling, count) in overlap where count >= threshold {
                        if isSpellingVariant(spelling, text) {
                            candidates.formUnion(spellings[spelling] ?? [])
                        }
                    }
                }
            }
            var result: Set<ID> = []
            for word in candidates {
                try Task.checkCancellation()
                if match(word, query: query) != nil { result.formUnion(words[word] ?? []) }
            }
            return result
        }

        private static func pairs(_ text: String) -> [String: Int] {
            var result: [String: Int] = [:]
            for (left, right) in zip(text, text.dropFirst()) {
                result[String([left, right]), default: 0] += 1
            }
            return result
        }

        fileprivate static func fragments(_ text: String, longestOnly: Bool = false) -> Set<UInt64> {
            let units = Array(text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                .decomposedStringWithCanonicalMapping.utf16)
            guard !units.isEmpty else { return [] }
            let maximum = min(3, units.count)
            var result: Set<UInt64> = []
            for length in (longestOnly ? maximum : 1)...maximum {
                for start in 0...(units.count - length) {
                    var key = UInt64(length) << 48
                    for offset in 0..<length { key |= UInt64(units[start + offset]) << (offset * 16) }
                    result.insert(key)
                }
            }
            return result
        }
    }

    fileprivate struct Token: Sendable {
        let word: Word
        let range: Range<String.Index>
    }

    fileprivate struct Word: Codable, Hashable, Sendable {
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
