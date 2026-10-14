import AVFoundation
import Foundation
import NativServerKit
import Observation

@MainActor
protocol ChatSpeechPlayback: AnyObject {
    var onFinish: ((String?) -> Void)? { get set }
    func play() -> Bool
    func stop()
}

/// Owns one response's synthesis and playback for the visible transcript.
@MainActor
@Observable
final class ChatResponseSpeech {
    enum Phase: Equatable {
        case idle, generating, playing
    }

    private(set) var messageID: UUID?
    private(set) var phase: Phase = .idle
    var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var playback: (any ChatSpeechPlayback)?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private let synthesize: @MainActor (String, NativSettings) async throws -> Data
    @ObservationIgnored private let makePlayback: @MainActor (Data) throws -> any ChatSpeechPlayback

    init(
        synthesize: @escaping @MainActor (String, NativSettings) async throws -> Data = { text, settings in
            guard let modelID = settings.textToSpeechModelID else {
                throw ChatResponseSpeechError.modelNotSelected
            }
            return try await NativAudioClient(
                baseURL: settings.serverBaseURL,
                apiKey: settings.serverAPIKey
            ).synthesize(text: text, model: modelID)
        },
        makePlayback: @escaping @MainActor (Data) throws -> any ChatSpeechPlayback = {
            try ChatResponseAudioPlayback(data: $0)
        }
    ) {
        self.synthesize = synthesize
        self.makePlayback = makePlayback
    }

    func toggle(messageID: UUID, text: String, settings: NativSettings) {
        if self.messageID == messageID {
            stop()
            return
        }

        stop()
        errorMessage = nil
        let settings = settings.normalized()
        guard settings.textToSpeechModelID != nil else {
            errorMessage = ChatResponseSpeechError.modelNotSelected.localizedDescription
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let requestID = UUID()
        self.requestID = requestID
        self.messageID = messageID
        phase = .generating
        task = Task { [weak self, synthesize] in
            do {
                let data = try await synthesize(text, settings)
                try Task.checkCancellation()
                guard let self, self.requestID == requestID else { return }
                let playback = try self.makePlayback(data)
                playback.onFinish = { [weak self] error in
                    guard let self, self.requestID == requestID else { return }
                    self.stop()
                    self.errorMessage = error
                }
                self.playback = playback
                guard playback.play() else {
                    throw ChatResponseSpeechError.playbackUnavailable
                }
                self.phase = .playing
                self.task = nil
            } catch {
                guard let self, self.requestID == requestID else { return }
                let cancelled = Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                self.stop()
                if !cancelled { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stop() {
        requestID = nil
        task?.cancel()
        task = nil
        playback?.onFinish = nil
        playback?.stop()
        playback = nil
        messageID = nil
        phase = .idle
    }
}

private enum ChatResponseSpeechError: LocalizedError {
    case modelNotSelected
    case playbackUnavailable

    var errorDescription: String? {
        switch self {
        case .modelNotSelected:
            "Choose a text-to-speech model in Models before reading aloud."
        case .playbackUnavailable:
            "The response audio could not be played."
        }
    }
}

@MainActor
private final class ChatResponseAudioPlayback: NSObject, ChatSpeechPlayback, AVAudioPlayerDelegate {
    var onFinish: ((String?) -> Void)?
    private let player: AVAudioPlayer

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.onFinish?(flag ? nil : ChatResponseSpeechError.playbackUnavailable.localizedDescription)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let message = error?.localizedDescription ?? "The response audio could not be decoded."
        Task { @MainActor [weak self] in self?.onFinish?(message) }
    }
}
