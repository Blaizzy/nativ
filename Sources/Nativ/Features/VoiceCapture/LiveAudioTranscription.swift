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
    case modelDoesNotSupportRealtime
}

final class LiveAudioTranscriptionPipeline: @unchecked Sendable {
    let emitter: LiveAudioPCMEmitter

    private let session: NativRealtimeTranscriptionSession
    private let modelID: String
    private let transcriptURL: URL
    private var preparationTask: Task<Void, Never>?

    init(
        recordingURL: URL,
        configuration: VoiceTranscriptionConfiguration,
        onTranscriptUpdate: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
    ) async throws {
        guard configuration.serverIsRunning else {
            throw LiveAudioTranscriptionPipelineError.serverNotRunning
        }

        let transcriptURL = recordingURL
            .deletingPathExtension()
            .appendingPathExtension("txt")
        self.transcriptURL = transcriptURL
        let transcriptWriter = try AudioTranscriptFileWriter(url: transcriptURL)
        let installedModels = try await LocalModelDiscovery.scan(
            searchPaths: LocalModelSearchPaths(
                primary: configuration.modelSearchPath,
                additional: configuration.additionalModelSearchPaths
            )
        )
        guard let modelID = LocalModelDiscovery.speechToTextModelID(
            in: installedModels,
            selectedModelID: configuration.selectedModelID
        ), let model = installedModels.first(where: { $0.repoID == modelID }) else {
            throw LiveAudioTranscriptionPipelineError.missingSpeechModel
        }
        guard Self.supportsRealtimeStreaming(model) else {
            throw LiveAudioTranscriptionPipelineError.modelDoesNotSupportRealtime
        }
        self.modelID = modelID

        let session = try NativRealtimeTranscriptionSession(
            baseURL: configuration.serverBaseURL,
            apiKey: configuration.serverAPIKey,
            model: modelID
        ) { transcript in
            try await transcriptWriter.replace(with: transcript)
            await onTranscriptUpdate(transcript)
        }
        self.session = session
        emitter = LiveAudioPCMEmitter { data, sampleRate in
            try await session.append(pcm16: data, sampleRate: sampleRate)
        }
        preparationTask = Task {
            try? await session.prepare()
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
        try? FileManager.default.removeItem(at: transcriptURL)
    }

    private static func supportsRealtimeStreaming(_ model: LocalModel) -> Bool {
        guard let snapshotURL = model.snapshotURL,
              let data = try? Data(contentsOf: snapshotURL.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = (config["model_type"] as? String)?.lowercased()
        else {
            return false
        }
        return modelType == "nemotron_asr" || modelType == "voxtral_realtime"
    }
}

final class LiveAudioPCMEmitter: @unchecked Sendable {
    typealias Send = @Sendable (Data, Int) async throws -> Void

    private let send: Send
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var firstError: Error?

    init(send: @escaping Send) {
        self.send = send
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        let packet = try Self.packet(from: buffer)
        lock.withLock {
            let preceding = tail
            tail = Task { [weak self] in
                await preceding?.value
                guard let self, !Task.isCancelled else { return }
                do {
                    try await send(packet.data, packet.sampleRate)
                } catch {
                    lock.withLock {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }
            }
        }
    }

    func finish() {}

    func drain() async throws {
        let finalTask = lock.withLock { tail }
        await finalTask?.value
        if let firstError = lock.withLock({ firstError }) {
            throw firstError
        }
    }

    func cancel() {
        lock.withLock {
            tail?.cancel()
            tail = nil
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
