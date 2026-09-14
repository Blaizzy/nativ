import Foundation

/// Separates spoken dictation commands before text reaches storage or the clipboard.
struct VoiceDictationTranscript: Equatable, Sendable {
    static let defaultReturnCommandTrigger = "enter"

    let text: String
    let pressReturn: Bool

    var isEmpty: Bool { text.isEmpty && !pressReturn }

    init(
        _ rawTranscript: String,
        returnCommandTrigger: String? = defaultReturnCommandTrigger
    ) {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggerWords = returnCommandTrigger?.split(whereSeparator: \.isWhitespace) ?? []
        let triggerPattern = triggerWords
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        // Require a standalone final phrase; tolerate punctuation added by the recognizer.
        // A comma before the command is a speech separator, but keep sentence punctuation.
        guard !triggerWords.isEmpty, let commandRange = trimmed.range(
            of: #"(?:^|,?\s+)"# + triggerPattern + #"[.!?,;:…]*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            text = trimmed
            pressReturn = false
            return
        }

        text = String(trimmed[..<commandRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pressReturn = true
    }
}
