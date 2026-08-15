import Foundation

struct NativStreamingMarkdownDocument: Equatable {
    /// An immutable source range that retains the same identity as append-only content grows.
    struct Chunk: Identifiable, Equatable {
        struct ID: Hashable {
            let lowerBoundCharacterOffset: Int
            let upperBoundCharacterOffset: Int
        }

        let id: ID
        let markdown: String
    }

    let completedChunks: [Chunk]
    let tail: String
}

enum NativMarkdownFormatting {
    /// Keeps the number of independent Textual views bounded while promoting completed blocks
    /// often enough to prevent the inline streaming tail from growing without limit.
    static let streamingChunkTargetLength = 1_200

    /// Splits append-only streaming Markdown into immutable completed chunks and one mutable tail.
    /// A boundary is not exposed until content from the following top-level block arrives, which
    /// prevents an unfinished list, fence, table, or math block from changing an existing chunk.
    static func streamingDocument(
        in markdown: String,
        minimumChunkLength: Int = streamingChunkTargetLength
    ) -> NativStreamingMarkdownDocument {
        guard !markdown.isEmpty else {
            return NativStreamingMarkdownDocument(completedChunks: [], tail: "")
        }

        let chunkLength = max(1, minimumChunkLength)
        let boundaries = stableStreamingBoundaries(in: markdown)
        var chunkStart = markdown.startIndex
        var completedChunks: [NativStreamingMarkdownDocument.Chunk] = []

        for boundary in boundaries {
            guard markdown.distance(from: chunkStart, to: boundary) >= chunkLength else {
                continue
            }

            let lowerBoundOffset = markdown.distance(from: markdown.startIndex, to: chunkStart)
            let upperBoundOffset = markdown.distance(from: markdown.startIndex, to: boundary)
            completedChunks.append(
                NativStreamingMarkdownDocument.Chunk(
                    id: .init(
                        lowerBoundCharacterOffset: lowerBoundOffset,
                        upperBoundCharacterOffset: upperBoundOffset
                    ),
                    markdown: String(markdown[chunkStart..<boundary])
                )
            )
            chunkStart = boundary
        }

        return NativStreamingMarkdownDocument(
            completedChunks: completedChunks,
            tail: String(markdown[chunkStart...])
        )
    }

    static func normalizedMathDelimiters(in markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var activeFence: CodeFence?
        var inlineCodeDelimiterLength: Int?
        var normalizedLines: [String] = []
        normalizedLines.reserveCapacity(lines.count)

        for line in lines {
            if let fence = activeFence {
                if isClosingFence(line, for: fence) {
                    activeFence = nil
                }
                normalizedLines.append(line)
                continue
            }

            if inlineCodeDelimiterLength == nil,
               let openingFence = codeFence(in: line)
            {
                activeFence = openingFence
                normalizedLines.append(line)
                continue
            }

            normalizedLines.append(
                normalizeMathDelimiters(
                    in: line,
                    inlineCodeDelimiterLength: &inlineCodeDelimiterLength
                )
            )
        }

        return normalizedLines.joined(separator: "\n")
    }

    private struct CodeFence {
        let marker: Character
        let length: Int
    }

    private struct StreamingLine {
        let startIndex: String.Index
        let content: Substring
    }

    private enum StreamingContainer {
        case list(indentation: Int)
        case blockQuote
        case indentedCode
        case other
    }

    private enum StreamingMathBlock {
        case dollars
        case brackets
    }

    private static func stableStreamingBoundaries(in markdown: String) -> [String.Index] {
        let lines = streamingLines(in: markdown)
        var activeFence: CodeFence?
        var activeMathBlock: StreamingMathBlock?
        var pendingBlankLine = false
        var precedingContainer = StreamingContainer.other
        var boundaries: [String.Index] = []

        for line in lines {
            let content = String(line.content)
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if let fence = activeFence {
                if isClosingFence(content, for: fence) {
                    activeFence = nil
                    precedingContainer = .other
                }
                continue
            }

            if let mathBlock = activeMathBlock {
                if closesStreamingMathBlock(mathBlock, trimmedLine: trimmed) {
                    activeMathBlock = nil
                    precedingContainer = .other
                }
                continue
            }

            if trimmed.isEmpty {
                pendingBlankLine = true
                continue
            }

            if pendingBlankLine {
                if !continuesStreamingContainer(precedingContainer, with: content) {
                    boundaries.append(line.startIndex)
                }
                pendingBlankLine = false
            }

            if let fence = codeFence(in: content) {
                activeFence = fence
                precedingContainer = .other
                continue
            }

            if let mathBlock = openingStreamingMathBlock(in: trimmed) {
                activeMathBlock = mathBlock
                precedingContainer = .other
                continue
            }

            precedingContainer = streamingContainer(
                for: content,
                continuing: precedingContainer
            )
        }

        return boundaries
    }

    private static func streamingLines(in markdown: String) -> [StreamingLine] {
        var lines: [StreamingLine] = []
        var lineStart = markdown.startIndex

        while lineStart < markdown.endIndex {
            let newline = markdown[lineStart...].firstIndex(of: "\n")
            let contentEnd = newline ?? markdown.endIndex
            let lineEnd = newline.map { markdown.index(after: $0) } ?? markdown.endIndex
            lines.append(
                StreamingLine(
                    startIndex: lineStart,
                    content: markdown[lineStart..<contentEnd]
                )
            )
            lineStart = lineEnd
        }

        return lines
    }

    private static func streamingContainer(
        for line: String,
        continuing previous: StreamingContainer
    ) -> StreamingContainer {
        if isBlockQuoteLine(line) {
            return .blockQuote
        }
        if let indentation = listMarkerIndentation(in: line) {
            return .list(indentation: indentation)
        }

        let indentation = leadingSpaceCount(in: line)
        switch previous {
        case .list(let listIndentation):
            if indentation > listIndentation || !lineStartsNewTopLevelBlock(line) {
                return previous
            }
        case .blockQuote:
            if !lineStartsNewTopLevelBlock(line) {
                return previous
            }
        case .indentedCode:
            if indentation >= 4 {
                return previous
            }
        case .other:
            break
        }

        return indentation >= 4 ? .indentedCode : .other
    }

    private static func continuesStreamingContainer(
        _ container: StreamingContainer,
        with line: String
    ) -> Bool {
        switch container {
        case .list(let indentation):
            return listMarkerIndentation(in: line) != nil
                || leadingSpaceCount(in: line) > indentation
        case .blockQuote:
            return isBlockQuoteLine(line)
        case .indentedCode:
            return leadingSpaceCount(in: line) >= 4
        case .other:
            return false
        }
    }

    private static func lineStartsNewTopLevelBlock(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else {
            return false
        }
        return first == "#" || first == ">" || codeFence(in: line) != nil
    }

    private static func listMarkerIndentation(in line: String) -> Int? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        guard indentation <= 3, index < line.endIndex else {
            return nil
        }

        if line[index] == "-" || line[index] == "+" || line[index] == "*" {
            let next = line.index(after: index)
            guard next < line.endIndex, line[next].isWhitespace else {
                return nil
            }
            return indentation
        }

        var digitCount = 0
        while index < line.endIndex, line[index].isNumber, digitCount < 10 {
            digitCount += 1
            index = line.index(after: index)
        }
        guard (1...9).contains(digitCount),
              index < line.endIndex,
              line[index] == "." || line[index] == ")"
        else {
            return nil
        }
        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else {
            return nil
        }
        return indentation
    }

    private static func isBlockQuoteLine(_ line: String) -> Bool {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }
        return indentation <= 3 && index < line.endIndex && line[index] == ">"
    }

    private static func leadingSpaceCount(in line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func openingStreamingMathBlock(
        in trimmedLine: String
    ) -> StreamingMathBlock? {
        if trimmedLine.hasPrefix("\\[")
            && !trimmedLine.dropFirst(2).contains("\\]")
        {
            return .brackets
        }
        if trimmedLine.hasPrefix("$$")
            && !trimmedLine.dropFirst(2).contains("$$")
        {
            return .dollars
        }
        return nil
    }

    private static func closesStreamingMathBlock(
        _ block: StreamingMathBlock,
        trimmedLine: String
    ) -> Bool {
        switch block {
        case .dollars:
            return trimmedLine.contains("$$")
        case .brackets:
            return trimmedLine.contains("\\]")
        }
    }

    private static func codeFence(in line: String) -> CodeFence? {
        var index = line.startIndex
        var indentation = 0

        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }

        guard indentation <= 3,
              index < line.endIndex,
              line[index] == "`" || line[index] == "~"
        else {
            return nil
        }

        let marker = line[index]
        let length = markerRunLength(in: line, from: index, marker: marker)
        guard length >= 3 else {
            return nil
        }

        return CodeFence(marker: marker, length: length)
    }

    private static func isClosingFence(_ line: String, for fence: CodeFence) -> Bool {
        guard let candidate = codeFence(in: line),
              candidate.marker == fence.marker,
              candidate.length >= fence.length
        else {
            return false
        }

        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
        }
        for _ in 0..<candidate.length {
            index = line.index(after: index)
        }

        return line[index...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func markerRunLength(
        in line: String,
        from startIndex: String.Index,
        marker: Character
    ) -> Int {
        var index = startIndex
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }
        return length
    }

    private static func normalizeMathDelimiters(
        in line: String,
        inlineCodeDelimiterLength: inout Int?
    ) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var index = line.startIndex

        while index < line.endIndex {
            if line[index] == "`" {
                let runLength = markerRunLength(in: line, from: index, marker: "`")
                result.append(String(repeating: "`", count: runLength))
                index = line.index(index, offsetBy: runLength)

                if inlineCodeDelimiterLength == runLength {
                    inlineCodeDelimiterLength = nil
                } else if inlineCodeDelimiterLength == nil {
                    inlineCodeDelimiterLength = runLength
                }
                continue
            }

            guard inlineCodeDelimiterLength == nil, line[index] == "\\" else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            let backslashCount = markerRunLength(in: line, from: index, marker: "\\")
            let nextIndex = line.index(index, offsetBy: backslashCount)
            guard backslashCount.isMultiple(of: 2) == false,
                  nextIndex < line.endIndex,
                  let replacement = mathDelimiterReplacement(for: line[nextIndex])
            else {
                result.append(String(repeating: "\\", count: backslashCount))
                index = nextIndex
                continue
            }

            result.append(String(repeating: "\\", count: backslashCount - 1))
            result.append(replacement)
            index = line.index(after: nextIndex)
        }

        return result
    }

    private static func mathDelimiterReplacement(for character: Character) -> String? {
        switch character {
        case "(", ")":
            return "$"
        case "[", "]":
            return "$$"
        default:
            return nil
        }
    }
}
