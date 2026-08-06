import AVFoundation
import Foundation
import Speech

/// On-device dictation through macOS's `SpeechAnalyzer`.
///
/// This exists so dictation works before any model has been downloaded. Nativ's normal
/// path needs an installed speech-to-text model *and* a running server; until both are in
/// place the shortcut records audio and then has nowhere to send it. macOS ships its own
/// speech models, needs no server, and transcribes at roughly 40–70× realtime, so it
/// covers first launch, a stopped server, and the moment a model is still downloading.
///
/// It is deliberately a fallback rather than an alternative: the bundled MLX models are
/// more accurate and support far more languages. This just removes the dead end.
///
/// `SpeechAnalyzer` is the macOS 26 successor to `SFSpeechRecognizer`, which the app's
/// deployment target lets us require outright. Two things follow. Recognition is on-device
/// by construction — the framework has no server mode to opt out of, so there is no path
/// in which audio leaves the Mac — and there is no one-minute ceiling on the audio, which
/// the older interface enforced by silently transcribing only the tail of a longer
/// recording and reporting success.
enum AppleSpeechTranscriber {
    enum Failure: LocalizedError {
        case languageUnsupported(String)
        case modelInstalling(String)
        case timedOut
        case empty

        var errorDescription: String? {
            switch self {
            case let .languageUnsupported(language):
                "macOS has no on-device speech model for \(language)."
            case let .modelInstalling(language):
                "macOS is still downloading its \(language) speech model."
            case .timedOut:
                "The system speech recognizer did not respond."
            case .empty:
                "No speech was recognized."
            }
        }
    }

    /// Model identifier recorded in dictation history, so a transcript produced by the
    /// fallback is distinguishable from one produced by an MLX model.
    static let modelIdentifier = "apple-speech (on-device)"

    /// Whether a fallback attempt is worth making — that is, whether macOS transcribes the
    /// user's language at all. Whether its model is on disk yet is settled later, once
    /// there is a recording to transcribe.
    static var isAvailable: Bool {
        get async { await transcriber() != nil }
    }

    /// Transcribes a recorded file. Nativ already writes dictation to disk before
    /// transcribing, so this takes a URL rather than tapping the microphone — it slots
    /// into the existing flow without changing how audio is captured.
    static func transcribe(contentsOf url: URL) async throws -> String {
        guard let transcriber = await transcriber() else {
            throw Failure.languageUnsupported(displayName(of: .current))
        }
        guard await isModelInstalled(transcriber) else {
            throw Failure.modelInstalling(displayName(of: transcriber.locale))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        let transcript: String
        do {
            transcript = try await withTimeout(after: timeout(forAudioAt: url)) {
                // The results have to be draining before analysis starts, otherwise they
                // are produced with nothing collecting them.
                async let collected = transcriber.transcript()
                _ = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: url))
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collected
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed
    }

    // MARK: - Choosing a transcriber

    /// A transcription module paired with the code that drains its results.
    private struct Transcriber {
        let module: any SpeechModule
        let locale: Locale
        /// Collects the module's output. Must be running before analysis begins.
        let transcript: @Sendable () async throws -> String
    }

    /// The module that covers the user's language, preferring quality over coverage.
    ///
    /// `SpeechTranscriber` is the better recognizer — on a 97 s clip it kept the sentence
    /// casing and punctuation that `DictationTranscriber` lost — but it covers 45 locales
    /// to the latter's 54. Dictation therefore picks up what it misses (Czech, Dutch,
    /// Polish, Russian, Swedish, Arabic, Hebrew and others), which for those users is the
    /// difference between a fallback and no fallback.
    ///
    /// `supportedLocale(equivalentTo:)` does the matching, and does it better than the
    /// hand-rolled ranking this file used to carry: it is deterministic, and it resolves
    /// regions macOS has no model for onto ones it does — `en-JP` to `en-GB`, `pt-AO` to
    /// `pt-PT`, a bare `de` to `de-DE`. A language with no model at all returns nil and
    /// the caller shows its usual alert, rather than transcribing, say, Welsh with an
    /// English model and inserting the result at the cursor.
    private static func transcriber() async -> Transcriber? {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            return Transcriber(module: module, locale: locale) {
                var text = AttributedString()
                for try await result in module.results where result.isFinal {
                    text += result.text
                }
                return String(text.characters)
            }
        }

        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
            let module = DictationTranscriber(locale: locale, preset: .longDictation)
            return Transcriber(module: module, locale: locale) {
                var text = AttributedString()
                for try await result in module.results where result.isFinal {
                    text += result.text
                }
                return String(text.characters)
            }
        }

        return nil
    }

    // MARK: - Model assets

    /// Whether the locale's model is ready to use, starting its download if it is not.
    ///
    /// macOS usually has the model already — system dictation draws on the same assets —
    /// but it reports `.supported` rather than `.installed` until the locale is allocated
    /// to this app, which is what `reserve` does. That call is the whole of the work in
    /// the common case: nothing is downloaded and the recording transcribes immediately.
    ///
    /// When the model genuinely is absent the download runs in the background rather than
    /// holding the dictation overlay open for an unknown length of time. This recording
    /// gets the caller's alert; the next one transcribes.
    private static func isModelInstalled(_ transcriber: Transcriber) async -> Bool {
        if await AssetInventory.status(forModules: [transcriber.module]) == .installed {
            return true
        }

        // Reservations are capped at five locales per app and Nativ only ever asks for the
        // one being dictated in, so exhausting them would take a deliberate tour through
        // five languages. Failing here is not fatal either: it costs the guarantee that
        // macOS keeps the model on disk, not the ability to transcribe with it.
        _ = try? await AssetInventory.reserve(locale: transcriber.locale)
        if await AssetInventory.status(forModules: [transcriber.module]) == .installed {
            return true
        }

        await ModelInstaller.shared.install(transcriber.module, locale: transcriber.locale)
        return false
    }

    /// Downloads a missing speech model, one installation per locale at a time so that
    /// repeated dictation attempts do not queue duplicate downloads.
    private actor ModelInstaller {
        static let shared = ModelInstaller()

        private var installing: Set<String> = []

        func install(_ module: any SpeechModule, locale: Locale) {
            let key = locale.identifier
            guard installing.insert(key).inserted else { return }

            Task {
                do {
                    let request = try await AssetInventory.assetInstallationRequest(
                        supporting: [module]
                    )
                    if let request {
                        try await request.downloadAndInstall()
                        NSLog("Nativ installed the macOS %@ speech model", key)
                    }
                } catch {
                    NSLog(
                        "Nativ could not install the macOS %@ speech model: %@",
                        key,
                        error.localizedDescription
                    )
                }
                finished(key)
            }
        }

        private func finished(_ key: String) {
            installing.remove(key)
        }
    }

    // MARK: - Helpers

    /// Recognition runs far faster than realtime, so a budget of the audio's own duration
    /// is generous while still ending a stalled recognizer rather than leaving the overlay
    /// spinning with no way back.
    private static func timeout(forAudioAt url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0
        else { return 30 }
        return max(30, Double(file.length) / file.processingFormat.sampleRate)
    }

    private static func withTimeout<Success: Sendable>(
        after seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> Success
    ) async throws -> Success {
        try await withThrowingTaskGroup(of: Success.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            return first
        }
    }

    private static func displayName(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.language.languageCode?.identifier
            ?? locale.identifier
    }
}
