import Foundation

/// Keeps only the last finalized word, never a transcript of background conversations.
struct VoiceWakeWordDetection {
    private var previousWord: String?
    private var previousEnd: TimeInterval = -.infinity

    mutating func consume(
        _ text: String,
        start: TimeInterval,
        end: TimeInterval,
        isFinal: Bool
    ) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var candidates = words
        if let previousWord, start >= previousEnd - 0.05, start - previousEnd <= 1 {
            candidates.insert(previousWord, at: 0)
        }
        // "Native" is the ordinary English spelling of the same spoken name.
        let detected = zip(candidates, candidates.dropFirst()).contains {
            $0 == "hey" && ($1 == "nativ" || $1 == "native")
        }
        if isFinal {
            previousWord = words.last
            previousEnd = end
        }
        return detected
    }
}

/// Used only by wake-word captures; keyboard captures retain their existing stop behavior.
struct VoiceWakeWordEndpoint {
    enum Action: Equatable { case finish, cancel }
    private var lastSpeechAt: TimeInterval?

    mutating func update(level: Float, elapsed: TimeInterval) -> Action? {
        // Ignore the activation chime and give the speaker time to begin.
        guard elapsed >= 0.6 else { return nil }
        if level >= 0.06 { lastSpeechAt = elapsed }
        if let lastSpeechAt, elapsed - lastSpeechAt >= 2 { return .finish }
        if lastSpeechAt == nil, elapsed >= 10 { return .cancel }
        if elapsed >= 120 { return .finish }
        return nil
    }
}
