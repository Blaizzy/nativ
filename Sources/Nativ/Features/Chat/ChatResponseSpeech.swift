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

/// Owns response playback and a short-lived, bounded audio cache for the visible transcript.
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
    @ObservationIgnored private var audioCache: [CacheKey: CachedAudio] = [:]
    @ObservationIgnored private var cacheExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var cacheAccess: UInt64 = 0
    @ObservationIgnored private let cacheLifetime: Duration
    @ObservationIgnored private let cacheByteLimit: Int
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    private struct CacheKey: Hashable {
        let messageID: UUID
        let text: String
        let modelID: String
        let serverURL: URL
        let apiKey: String?
    }

    private struct CachedAudio {
        let data: Data
        let expiresAt: ContinuousClock.Instant
        var lastAccess: UInt64
    }

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
        },
        cacheLifetime: Duration = .seconds(300),
        cacheByteLimit: Int = 64 * 1024 * 1024,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.synthesize = synthesize
        self.makePlayback = makePlayback
        self.cacheLifetime = cacheLifetime
        self.cacheByteLimit = cacheByteLimit
        self.now = now
    }

    deinit {
        cacheExpiryTask?.cancel()
    }

    func toggle(messageID: UUID, text: String, settings: NativSettings) {
        if self.messageID == messageID {
            stop()
            return
        }

        stop()
        errorMessage = nil
        let settings = settings.normalized()
        guard let modelID = settings.textToSpeechModelID else {
            errorMessage = ChatResponseSpeechError.modelNotSelected.localizedDescription
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let cacheKey = CacheKey(
            messageID: messageID, text: text, modelID: modelID,
            serverURL: settings.serverBaseURL, apiKey: settings.serverAPIKey
        )
        let cachedData = cachedAudio(for: cacheKey)
        let requestID = UUID()
        self.requestID = requestID
        self.messageID = messageID
        phase = .generating
        task = Task { [weak self, synthesize] in
            do {
                let data: Data
                if let cachedData {
                    data = cachedData
                } else {
                    data = try await synthesize(text, settings)
                }
                try Task.checkCancellation()
                guard let self, self.requestID == requestID else { return }
                let playback = try self.makePlayback(data)
                playback.onFinish = { [weak self] error in
                    guard let self, self.requestID == requestID else { return }
                    if error != nil { self.audioCache.removeValue(forKey: cacheKey) }
                    self.stop()
                    self.errorMessage = error
                }
                self.playback = playback
                guard playback.play() else {
                    throw ChatResponseSpeechError.playbackUnavailable
                }
                if cachedData == nil { self.cacheAudio(data, for: cacheKey) }
                self.phase = .playing
                self.task = nil
            } catch {
                guard let self, self.requestID == requestID else { return }
                let cancelled = Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                self.stop()
                if !cancelled {
                    self.audioCache.removeValue(forKey: cacheKey)
                    self.errorMessage = error.localizedDescription
                }
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

    private func cachedAudio(for key: CacheKey) -> Data? {
        pruneExpiredAudio()
        guard var entry = audioCache[key] else { return nil }
        cacheAccess += 1
        entry.lastAccess = cacheAccess
        audioCache[key] = entry
        return entry.data
    }

    private func cacheAudio(_ data: Data, for key: CacheKey) {
        guard cacheLifetime > .zero, !data.isEmpty, data.count <= cacheByteLimit else { return }
        pruneExpiredAudio()
        cacheAccess += 1
        audioCache[key] = CachedAudio(
            data: data, expiresAt: now().advanced(by: cacheLifetime), lastAccess: cacheAccess
        )
        // Bound both audio bytes and retained message text; evict the least recently played clip.
        while audioCache.count > 32 || audioCache.values.reduce(0, { $0 + $1.data.count }) > cacheByteLimit {
            guard let oldest = audioCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            audioCache.removeValue(forKey: oldest)
        }
        scheduleCacheExpiry()
    }

    private func pruneExpiredAudio() {
        let currentTime = now()
        audioCache = audioCache.filter { $0.value.expiresAt > currentTime }
    }

    private func scheduleCacheExpiry() {
        cacheExpiryTask?.cancel()
        cacheExpiryTask = nil
        guard let nextExpiry = audioCache.values.map(\.expiresAt).min() else { return }
        let delay = now().duration(to: nextExpiry)
        // Release cached buffers even when the user never plays another response.
        cacheExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: max(delay, .zero)) } catch { return }
            guard let self else { return }
            self.pruneExpiredAudio()
            self.scheduleCacheExpiry()
        }
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
