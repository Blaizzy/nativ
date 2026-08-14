import Foundation

enum NativMarkdownFormatting {
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
