import AVFoundation
import Foundation
import NativServerKit

struct VoiceTranscriptionConfiguration: Sendable {
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    let selectedModelID: String?
    let languageModelID: String?
    let maxTokens: Int
    let serverBaseURL: URL
    let serverAPIKey: String?
    let serverIsRunning: Bool
}

struct StreamingVoiceTranscriptState {
    private let commandWords: [String]
    private(set) var insertedText = ""

    init(returnCommandTrigger: String?) {
        commandWords = returnCommandTrigger?
            .split(whereSeparator: \.isWhitespace)
            .map { Self.normalized(String($0)) } ?? []
    }

    mutating func incrementalText(for transcript: String) -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        let maximumCandidate = min(words.count, commandWords.count)
        let heldWordCount = stride(
            from: maximumCandidate,
            through: 1,
            by: -1
        ).first { count in
            zip(words.suffix(count), commandWords.prefix(count)).allSatisfy {
                Self.normalized(String($0)) == $1
            }
        } ?? 0
        let stableWordCount = words.count - heldWordCount
        return suffix(toReach: words.prefix(stableWordCount).joined(separator: " "))
    }

    mutating func finalText(for transcript: String) -> String {
        suffix(toReach: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private mutating func suffix(toReach text: String) -> String {
        guard text != insertedText else { return "" }
        guard text.hasPrefix(insertedText) else { return "" }
        let suffix = String(text.dropFirst(insertedText.count))
        insertedText = text
        return suffix
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

enum LiveAudioTranscriptionPipelineError: Error {
    case serverNotRunning
    case missingSpeechModel
}

enum LiveAudioPCMEmitterError: Error {
    case backlogExceeded
}

final class LiveAudioTranscriptionPipeline: @unchecked Sendable {
    let emitter: LiveAudioPCMEmitter

    private let session: NativRealtimeTranscriptionSession
    private let modelID: String
    private var preparationTask: Task<Void, Error>?

    init(
        configuration: VoiceTranscriptionConfiguration,
        onTranscriptUpdate: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
    ) async throws {
        guard configuration.serverIsRunning else {
            throw LiveAudioTranscriptionPipelineError.serverNotRunning
        }

        let installedModels = try await LocalModelDiscovery.scan(
            searchPaths: LocalModelSearchPaths(
                primary: configuration.modelSearchPath,
                additional: configuration.additionalModelSearchPaths
            )
        )
        guard let modelID = LocalModelDiscovery.speechToTextModelID(
            in: installedModels,
            selectedModelID: configuration.selectedModelID
        ) else {
            throw LiveAudioTranscriptionPipelineError.missingSpeechModel
        }
        self.modelID = modelID

        let session = try NativRealtimeTranscriptionSession(
            baseURL: configuration.serverBaseURL,
            apiKey: configuration.serverAPIKey,
            model: modelID
        ) { transcript in await onTranscriptUpdate(transcript) }
        self.session = session
        let preparationTask = Task {
            try await session.prepare()
        }
        self.preparationTask = preparationTask
        emitter = LiveAudioPCMEmitter { data, sampleRate in
            try await preparationTask.value
            try await session.append(pcm16: data, sampleRate: sampleRate)
        }
    }

    func finish() async throws -> (transcript: String, modelID: String) {
        try await emitter.drain()
        let transcript = try await session.finish()
        return (transcript, modelID)
    }

    func cancel() async {
        preparationTask?.cancel()
        preparationTask = nil
        emitter.cancel()
        await session.cancel()
    }

}

final class LiveAudioPCMEmitter: @unchecked Sendable {
    typealias Send = @Sendable (Data, Int) async throws -> Void

    private struct Packet {
        let data: Data
        let sampleRate: Int
    }

    private let send: Send
    private let lock = NSLock()
    private let maximumPendingPackets: Int
    private var packets: [Packet] = []
    private var packetWaiter: CheckedContinuation<Packet?, Never>?
    private var worker: Task<Void, Never>?
    private var firstError: Error?
    private var isFinished = false
    private var isCancelled = false

    init(maximumPendingPackets: Int = 256, send: @escaping Send) {
        self.maximumPendingPackets = maximumPendingPackets
        self.send = send
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        let packet = try Self.packet(from: buffer)
        try lock.withLock {
            guard !isCancelled else { throw CancellationError() }
            guard !isFinished else { return }
            if let packetWaiter {
                self.packetWaiter = nil
                packetWaiter.resume(returning: Packet(
                    data: packet.data,
                    sampleRate: packet.sampleRate
                ))
            } else {
                guard packets.count < maximumPendingPackets else {
                    throw LiveAudioPCMEmitterError.backlogExceeded
                }
                packets.append(Packet(data: packet.data, sampleRate: packet.sampleRate))
            }
            if worker == nil {
                worker = Task { [weak self] in await self?.run() }
            }
        }
    }

    func finish() {
        lock.withLock {
            isFinished = true
            if packets.isEmpty, let packetWaiter {
                self.packetWaiter = nil
                packetWaiter.resume(returning: nil)
            }
        }
    }

    func drain() async throws {
        finish()
        let finalWorker = lock.withLock { worker }
        await finalWorker?.value
        if let firstError = lock.withLock({ firstError }) {
            throw firstError
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            packets.removeAll()
            worker?.cancel()
            if let packetWaiter {
                self.packetWaiter = nil
                packetWaiter.resume(returning: nil)
            }
        }
    }

    private func run() async {
        while !Task.isCancelled, let packet = await nextPacket() {
            do {
                try await send(packet.data, packet.sampleRate)
            } catch {
                lock.withLock {
                    if firstError == nil { firstError = error }
                    isFinished = true
                    packets.removeAll()
                }
                break
            }
        }
    }

    private func nextPacket() async -> Packet? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if !packets.isEmpty {
                    continuation.resume(returning: packets.removeFirst())
                } else if isFinished || isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    packetWaiter = continuation
                }
            }
        }
    }

    private static func packet(from buffer: AVAudioPCMBuffer) throws -> (
        data: Data,
        sampleRate: Int
    ) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: buffer.format, to: format),
        let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: buffer.frameLength
        ) else {
            throw VoiceAudioRecorderError.couldNotConvert
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !suppliedInput else {
                state.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            throw conversionError ?? VoiceAudioRecorderError.couldNotConvert as NSError
        }
        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else {
            throw VoiceAudioRecorderError.couldNotConvert
        }
        return (
            Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize)),
            Int(format.sampleRate)
        )
    }
}
