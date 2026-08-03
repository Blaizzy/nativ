import Foundation
import Speech
import os

/// On-device dictation through Apple's Speech framework.
///
/// This exists so dictation works before any model has been downloaded. Nativ's normal
/// path needs an installed speech-to-text model *and* a running server; until both are
/// in place the shortcut records audio and then has nowhere to send it. Apple's
/// recognizer ships with macOS, needs no weights, and answers in well under a second,
/// so it covers first launch, a stopped server, and the moment a model is still
/// downloading.
///
/// It is deliberately a fallback rather than an alternative: the bundled MLX models are
/// more accurate and support far more languages. This just removes the dead end.
///
/// **Recognition is pinned on-device.** `SFSpeechRecognizer` will happily stream audio to
/// Apple's servers when a locale has no local model, which would be the wrong default for
/// an app whose whole premise is that nothing leaves the Mac. `requiresOnDeviceRecognition`
/// is set unconditionally and the locale is rejected outright when it has no on-device
/// support, so a missing local model produces an error rather than a silent upload.
enum AppleSpeechTranscriber {
    enum Failure: LocalizedError {
        case notAuthorized
        case onDeviceUnavailable(locale: String)
        case recognizerUnavailable
        case timedOut
        case empty

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Nativ is not allowed to use speech recognition."
            case let .onDeviceUnavailable(locale):
                "macOS has no on-device speech model for \(locale)."
            case .recognizerUnavailable:
                "The system speech recognizer is unavailable."
            case .timedOut:
                "The system speech recognizer did not respond."
            case .empty:
                "No speech was recognized."
            }
        }
    }

    /// Dictation clips are short and on-device recognition is fast, so anything beyond
    /// this is a stall rather than slow progress.
    private static let timeoutSeconds: TimeInterval = 30

    /// Keeps the in-flight recognition task alive and makes completion single-shot.
    private final class RecognitionTaskHolder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var task: SFSpeechRecognitionTask?

        /// True for the first caller only.
        func claimCompletion() -> Bool {
            lock.withLock { completed in
                defer { completed = true }
                return !completed
            }
        }
    }

    /// Locale used for recognition: the closest supported match to the user's own that
    /// actually has an on-device model.
    ///
    /// Two traps here. `supportedLocales()` returns an unordered `Set`, so picking with
    /// `first(where:)` yields a different answer between runs — an en-GB user could get
    /// en-ID one launch and en-AU the next. And `Locale.current.identifier` uses
    /// underscores (`en_GB`) while the supported list uses hyphens (`en-GB`), so the exact
    /// match silently never fires. Candidates are therefore normalized, ranked, and
    /// tie-broken by identifier so the choice is stable.
    ///
    /// Ranking also skips locales macOS lists but has no downloaded asset for, because
    /// on-device recognition is mandatory here — a supported-but-absent locale would fail
    /// the whole transcription rather than quietly falling back to a neighbouring one.
    static var preferredLocale: Locale {
        let current = Locale.current
        let currentID = normalizedIdentifier(current.identifier)
        let currentLanguage = current.language.languageCode?.identifier
        let currentRegion = current.region?.identifier

        func rank(_ locale: Locale) -> Int? {
            let identifier = normalizedIdentifier(locale.identifier)
            if identifier == currentID { return 0 }
            guard let currentLanguage,
                  locale.language.languageCode?.identifier == currentLanguage
            else { return identifier == "en-US" ? 3 : nil }
            return locale.region?.identifier == currentRegion ? 1 : 2
        }

        let ranked = SFSpeechRecognizer.supportedLocales()
            .compactMap { locale -> (Locale, Int)? in
                rank(locale).map { (locale, $0) }
            }
            .sorted {
                $0.1 == $1.1
                    ? normalizedIdentifier($0.0.identifier) < normalizedIdentifier($1.0.identifier)
                    : $0.1 < $1.1
            }
            .map(\.0)

        return ranked.first(where: hasOnDeviceModel)
            ?? ranked.first
            ?? Locale(identifier: "en-US")
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    private static func hasOnDeviceModel(_ locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Whether a fallback attempt is worth making.
    ///
    /// `notDetermined` counts as available: permission is requested by the first
    /// transcription, and requiring `authorized` here would deadlock — the fallback would
    /// never run, so the prompt would never appear, so the status would never leave
    /// `notDetermined`. A denied or restricted status is permanent until the user changes
    /// it in System Settings, so it returns false and the caller shows its normal alert
    /// instead of prompting on every recording.
    static var isAvailable: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined:
            break
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        return hasOnDeviceModel(preferredLocale)
    }

    /// Prompts for permission the first time. Safe to call repeatedly; macOS only shows
    /// the dialog while the status is `notDetermined`.
    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes a recorded file. Nativ already writes dictation to disk before
    /// transcribing, so this takes a URL rather than tapping the microphone — it slots
    /// into the existing flow without changing how audio is captured.
    static func transcribe(contentsOf url: URL) async throws -> String {
        guard await requestAuthorization() else { throw Failure.notAuthorized }

        let locale = preferredLocale
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw Failure.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw Failure.onDeviceUnavailable(
                locale: locale.localizedString(forIdentifier: locale.identifier)
                    ?? locale.identifier
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true   // never leaves the Mac
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let transcript: String = try await withCheckedThrowingContinuation { continuation in
            // The task must be held for the duration of recognition. Discarding the
            // returned object lets ARC release it, and the result handler then never
            // fires — the call simply hangs. The holder is captured by both closures
            // below, which keeps it alive exactly as long as it is needed.
            let holder = RecognitionTaskHolder()

            func finish(_ result: Result<String, Error>) {
                // The handler fires for partial results and cancellations as well as the
                // final result, so resuming must happen at most once.
                guard holder.claimCompletion() else { return }
                holder.task?.cancel()
                holder.task = nil
                continuation.resume(with: result)
            }

            // A stalled recognizer would otherwise leave dictation waiting forever, with
            // the overlay spinning and no way back. Failing here surfaces the normal
            // "no model / server stopped" alert instead.
            let timeout = DispatchWorkItem { finish(.failure(Failure.timedOut)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)

            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let code = (error as NSError).code
                    // 216 is "cancelled", which arrives after a successful final result.
                    if code == 216 { return }
                    timeout.cancel()
                    // 1110 is "no speech detected". It is a normal outcome for a recording
                    // that caught only silence, so it is reported as `.empty` and gets the
                    // usual no-speech feedback rather than an error alert.
                    finish(.failure(code == 1110 ? Failure.empty : error))
                    return
                }
                guard let result, result.isFinal else { return }
                timeout.cancel()
                finish(.success(result.bestTranscription.formattedString))
            }
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed
    }

    /// Model identifier recorded in dictation history, so a transcript produced by the
    /// fallback is distinguishable from one produced by an MLX model.
    static let modelIdentifier = "apple-speech (on-device)"
}
