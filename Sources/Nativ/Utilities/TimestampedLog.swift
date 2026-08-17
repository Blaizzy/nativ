import Foundation

enum TimestampedLog {
    private static let timestampParser = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    static func append(
        _ input: String,
        receivedAt: Date = .now,
        to output: inout String,
        isAtLineStart: inout Bool,
        maximumCharacterCount: Int
    ) {
        guard !input.isEmpty else { return }

        let formattedDate = timestampParser.format(receivedAt)
        let timestamp = "[\(formattedDate)] "
        var timestampedInput = ""
        timestampedInput.reserveCapacity(input.count + timestamp.count)

        for character in input {
            if isAtLineStart && !character.isNewline {
                timestampedInput.append(timestamp)
                isAtLineStart = false
            }

            timestampedInput.append(character)
            if character.isNewline {
                isAtLineStart = true
            }
        }

        output.append(timestampedInput)
        trim(&output, toMaximumCharacterCount: maximumCharacterCount)
    }

    static func components(in line: String) -> (date: Date, message: String)? {
        guard line.first == "[",
              let closingBracket = line.firstIndex(of: "]")
        else {
            return nil
        }

        let timestampStart = line.index(after: line.startIndex)
        let rawTimestamp = String(line[timestampStart..<closingBracket])
        guard let date = try? timestampParser.parse(rawTimestamp) else {
            return nil
        }

        var messageStart = line.index(after: closingBracket)
        if messageStart < line.endIndex, line[messageStart] == " " {
            messageStart = line.index(after: messageStart)
        }
        return (date, String(line[messageStart...]))
    }

    private static func trim(_ output: inout String, toMaximumCharacterCount limit: Int) {
        guard limit > 0, output.count > limit else { return }

        let overflow = output.count - limit
        let boundary = output.index(output.startIndex, offsetBy: overflow)

        if boundary > output.startIndex {
            let precedingCharacter = output[output.index(before: boundary)]
            if precedingCharacter.isNewline {
                output.removeSubrange(..<boundary)
                return
            }
        }

        if let nextLineBreak = output[boundary...].firstIndex(where: \.isNewline) {
            output.removeSubrange(...nextLineBreak)
        } else {
            // A single unusually long event should stay bounded while retaining
            // the timestamp at its beginning.
            output = String(output.prefix(limit))
        }
    }
}
