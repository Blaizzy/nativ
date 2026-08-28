import Foundation

enum FileEditEngineError: Error, Equatable, Sendable {
    case invalidPatch(String)
    case oldStringNotFound
    case ambiguousMatch(Int)
}

struct FileTextReplacement: Equatable, Sendable {
    let oldText: String
    let newText: String
}

enum FilePatchOperation: Equatable, Sendable {
    case add(path: String, content: String)
    case update(path: String, replacements: [FileTextReplacement], moveTo: String?)
    case delete(path: String)
    case move(path: String, destination: String)

    var paths: [String] {
        switch self {
        case .add(let path, _), .delete(let path): [path]
        case .update(let path, _, let moveTo): [path] + (moveTo.map { [$0] } ?? [])
        case .move(let path, let destination): [path, destination]
        }
    }
}

enum V4AFilePatchParser {
    static func parse(_ patch: String) throws -> [FilePatchOperation] {
        let normalized =
            patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "*** Begin Patch", lines.last == "*** End Patch" else {
            throw FileEditEngineError.invalidPatch(
                "Patch mode requires *** Begin Patch and *** End Patch markers."
            )
        }

        var operations: [FilePatchOperation] = []
        var index = 1
        while index < lines.count - 1 {
            let header = lines[index]
            if header.hasPrefix("*** Add File: ") {
                let path = String(header.dropFirst("*** Add File: ".count))
                index += 1
                var contentLines: [String] = []
                while index < lines.count - 1, !lines[index].hasPrefix("*** ") {
                    guard lines[index].hasPrefix("+") else {
                        throw FileEditEngineError.invalidPatch(
                            "Every Add File content line must start with +."
                        )
                    }
                    contentLines.append(String(lines[index].dropFirst()))
                    index += 1
                }
                let content =
                    contentLines.isEmpty ? "" : contentLines.joined(separator: "\n") + "\n"
                operations.append(.add(path: path, content: content))
                continue
            }
            if header.hasPrefix("*** Delete File: ") {
                operations.append(
                    .delete(
                        path: String(header.dropFirst("*** Delete File: ".count))
                    ))
                index += 1
                continue
            }
            if header.hasPrefix("*** Move File: ") {
                let path = String(header.dropFirst("*** Move File: ".count))
                index += 1
                guard index < lines.count - 1, lines[index].hasPrefix("*** Move to: ") else {
                    throw FileEditEngineError.invalidPatch(
                        "Move File requires a following Move to header.")
                }
                let destination = String(lines[index].dropFirst("*** Move to: ".count))
                operations.append(.move(path: path, destination: destination))
                index += 1
                continue
            }
            if header.hasPrefix("*** Update File: ") {
                let path = String(header.dropFirst("*** Update File: ".count))
                index += 1
                var moveTo: String?
                if index < lines.count - 1, lines[index].hasPrefix("*** Move to: ") {
                    moveTo = String(lines[index].dropFirst("*** Move to: ".count))
                    index += 1
                }
                var replacements: [FileTextReplacement] = []
                var oldLines: [String] = []
                var newLines: [String] = []

                func finishHunk() {
                    guard !oldLines.isEmpty || !newLines.isEmpty else { return }
                    replacements.append(
                        FileTextReplacement(
                            oldText: oldLines.joined(separator: "\n"),
                            newText: newLines.joined(separator: "\n")
                        ))
                    oldLines.removeAll(keepingCapacity: true)
                    newLines.removeAll(keepingCapacity: true)
                }

                while index < lines.count - 1, !lines[index].hasPrefix("*** ") {
                    let line = lines[index]
                    if line.hasPrefix("@@") {
                        finishHunk()
                    } else if line.hasPrefix(" ") {
                        let value = String(line.dropFirst())
                        oldLines.append(value)
                        newLines.append(value)
                    } else if line.hasPrefix("-") {
                        oldLines.append(String(line.dropFirst()))
                    } else if line.hasPrefix("+") {
                        newLines.append(String(line.dropFirst()))
                    } else if line == "" {
                        oldLines.append("")
                        newLines.append("")
                    } else {
                        throw FileEditEngineError.invalidPatch(
                            "Update File hunk lines must start with space, +, -, or @@."
                        )
                    }
                    index += 1
                }
                finishHunk()
                guard !replacements.isEmpty || moveTo != nil else {
                    throw FileEditEngineError.invalidPatch("Update File contains no changes.")
                }
                operations.append(.update(path: path, replacements: replacements, moveTo: moveTo))
                continue
            }
            throw FileEditEngineError.invalidPatch("Unsupported patch header: \(header)")
        }
        guard !operations.isEmpty else {
            throw FileEditEngineError.invalidPatch("The patch contains no file operations.")
        }
        return operations
    }
}

enum FuzzyFileTextReplacer {
    static func replacing(
        in source: String,
        oldText: String,
        newText: String,
        replaceAll: Bool
    ) throws -> String {
        guard !oldText.isEmpty else {
            throw FileEditEngineError.invalidPatch("old_string must not be empty.")
        }

        let exactRanges = ranges(of: oldText, in: source)
        if !exactRanges.isEmpty {
            guard replaceAll || exactRanges.count == 1 else {
                throw FileEditEngineError.ambiguousMatch(exactRanges.count)
            }
            return replacingRanges(
                replaceAll ? exactRanges : [exactRanges[0]],
                in: source,
                with: newText
            )
        }

        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let normalizedSource = normalizeNewlines(source)
        let sourceHasTrailingNewline = normalizedSource.hasSuffix("\n")
        let sourceLines = splitLines(normalizedSource)
        let oldLines = splitLines(normalizeNewlines(oldText))
        let newLines = splitLines(normalizeNewlines(newText))
        guard !oldLines.isEmpty, oldLines.count <= sourceLines.count else {
            throw FileEditEngineError.oldStringNotFound
        }

        let strategies: [(String) -> String] = [
            { Self.trimTrailingWhitespace($0) },
            { Self.trimLeadingWhitespace($0) },
            { Self.trimEveryLine($0) },
            { Self.collapseHorizontalWhitespace($0) },
            { Self.removeAllWhitespace($0) },
            { Self.dedent($0) },
            { Self.removeBlankLines(Self.trimEveryLine($0)) },
            { Self.punctuationNormalized(Self.collapseHorizontalWhitespace($0)) },
        ]

        for strategy in strategies {
            let transformedOld = strategy(oldLines.joined(separator: "\n"))
            var matches: [Range<Int>] = []
            for start in 0 ... (sourceLines.count - oldLines.count) {
                let end = start + oldLines.count
                let candidate = sourceLines[start ..< end].joined(separator: "\n")
                if strategy(candidate) == transformedOld {
                    matches.append(start ..< end)
                }
            }
            guard !matches.isEmpty else { continue }
            guard replaceAll || matches.count == 1 else {
                throw FileEditEngineError.ambiguousMatch(matches.count)
            }

            var result = sourceLines
            for match in (replaceAll ? matches : [matches[0]]).reversed() {
                result.replaceSubrange(match, with: newLines)
            }
            var joined = result.joined(separator: "\n")
            if sourceHasTrailingNewline, !joined.hasSuffix("\n") { joined += "\n" }
            return newline == "\r\n"
                ? joined.replacingOccurrences(of: "\n", with: "\r\n")
                : joined
        }
        throw FileEditEngineError.oldStringNotFound
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart <= haystack.endIndex,
            let range = haystack.range(of: needle, range: searchStart ..< haystack.endIndex)
        {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    private static func replacingRanges(
        _ ranges: [Range<String.Index>],
        in source: String,
        with replacement: String
    ) -> String {
        var result = source
        for range in ranges.reversed() { result.replaceSubrange(range, with: replacement) }
        return result
    }

    private static func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private static func splitLines(_ value: String) -> [String] {
        var lines = value.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func trimTrailingWhitespace(_ value: String) -> String {
        value.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func trimLeadingWhitespace(_ value: String) -> String {
        value.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func trimEveryLine(_ value: String) -> String {
        value.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func collapseHorizontalWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }

    private static func removeAllWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func dedent(_ value: String) -> String {
        let lines = value.components(separatedBy: "\n")
        let indent =
            lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.count))) }.joined(separator: "\n")
    }

    private static func removeBlankLines(_ value: String) -> String {
        value.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func punctuationNormalized(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\s*([=,:;{}\[\]()])\s*"#,
            with: "$1",
            options: .regularExpression
        )
    }
}

enum FileUnifiedDiff {
    static func render(path: String, before: String?, after: String?) -> String {
        let beforeLines = before.map(lines) ?? []
        let afterLines = after.map(lines) ?? []
        var output = [
            "--- \(before == nil ? "/dev/null" : path)",
            "+++ \(after == nil ? "/dev/null" : path)", "@@",
        ]
        output.append(contentsOf: beforeLines.map { "-\($0)" })
        output.append(contentsOf: afterLines.map { "+\($0)" })
        let rendered = output.joined(separator: "\n")
        return rendered.count > 50_000
            ? String(rendered.prefix(50_000)) + "\n... diff truncated"
            : rendered
    }

    private static func lines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
    }
}
