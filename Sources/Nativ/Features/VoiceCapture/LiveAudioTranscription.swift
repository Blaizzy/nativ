import AVFoundation
import Foundation
import NativServerKit

struct LiveTranscriptMerger {
    static func merge(_ existing: String, with incoming: String) -> String {
        let existingWords = words(in: existing)
        let incomingWords = words(in: incoming)
        guard !existingWords.isEmpty else {
            return incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !incomingWords.isEmpty else {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let maximumOverlap = min(existingWords.count, incomingWords.count)
        let overlap = stride(from: maximumOverlap, through: 1, by: -1).first { count in
            zip(existingWords.suffix(count), incomingWords.prefix(count)).allSatisfy {
                normalized($0) == normalized($1)
            }
        } ?? 0
        let suffix = incomingWords.dropFirst(overlap).joined(separator: " ")
        guard !suffix.isEmpty else {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return existing.trimmingCharacters(in: .whitespacesAndNewlines)
            + " "
            + suffix
    }

    private static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    private static func normalized(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

final class LiveAudioTranscriptionSession: @unchecked Sendable {
    typealias Transcribe = @Sendable (URL) async throws -> String

    private let transcriptWriter: AudioTranscriptFileWriter
    private let transcribe: Transcribe
    private let onTranscriptUpdate: @MainActor @Sendable (String) -> Void
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var transcript = ""
    private var firstError: Error?

    init(
        transcriptWriter: AudioTranscriptFileWriter,
        transcribe: @escaping Transcribe,
        onTranscriptUpdate: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.transcriptWriter = transcriptWriter
        self.transcribe = transcribe
        self.onTranscriptUpdate = onTranscriptUpdate
    }

    func enqueue(_ chunkURL: URL) {
        lock.withLock {
            let precedingTask = tail
            let task = Task { [weak self] in
                defer { try? FileManager.default.removeItem(at: chunkURL) }
                await precedingTask?.value
                guard !Task.isCancelled else { return }
                await self?.process(chunkURL)
            }
            tail = task
            tasks.append(task)
        }
    }

    func finish() async throws -> String {
        let finalTask = lock.withLock { tail }
        await finalTask?.value
        return try lock.withLock {
            if let firstError {
                throw firstError
            }
            return transcript
        }
    }

    func cancel() async {
        let activeTasks = lock.withLock { () -> [Task<Void, Never>] in
            tasks.forEach { $0.cancel() }
            return tasks
        }
        for task in activeTasks {
            await task.value
        }
    }

    private func process(_ chunkURL: URL) async {
        do {
            try Task.checkCancellation()
            let chunkTranscript = try await transcribe(chunkURL)
            try Task.checkCancellation()
            let merged = lock.withLock {
                transcript = LiveTranscriptMerger.merge(transcript, with: chunkTranscript)
                return transcript
            }
            try await transcriptWriter.replace(with: merged)
            await onTranscriptUpdate(merged)
        } catch {
            lock.withLock {
                if firstError == nil {
                    firstError = error
                }
            }
        }
    }
}

final class LiveAudioChunkEmitter: @unchecked Sendable {
    private let directory: URL
    private let chunkDuration: TimeInterval
    private let overlapDuration: TimeInterval
    private let onChunk: @Sendable (URL) -> Void
    private var chunkFile: AVAudioFile?
    private var chunkURL: URL?
    private var chunkFrames: AVAudioFramePosition = 0
    private var newFrames: AVAudioFramePosition = 0
    private var overlapBuffers: [AVAudioPCMBuffer] = []
    private var overlapFrames: AVAudioFramePosition = 0
    private var sequence = 0

    init(
        directory: URL,
        chunkDuration: TimeInterval = 1.5,
        overlapDuration: TimeInterval = 0,
        onChunk: @escaping @Sendable (URL) -> Void
    ) {
        self.directory = directory
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
        self.onChunk = onChunk
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        if chunkFile == nil {
            try startChunk(format: buffer.format, includingOverlap: false)
        }
        try chunkFile?.write(from: buffer)
        chunkFrames += AVAudioFramePosition(buffer.frameLength)
        newFrames += AVAudioFramePosition(buffer.frameLength)
        retainForOverlap(buffer)

        let targetFrames = AVAudioFramePosition(buffer.format.sampleRate * chunkDuration)
        if chunkFrames >= targetFrames {
            try emitCurrentChunk(nextFormat: buffer.format)
        }
    }

    func finish() {
        guard let chunkURL else { return }
        chunkFile?.close()
        chunkFile = nil
        self.chunkURL = nil
        if newFrames > 0 {
            onChunk(chunkURL)
        } else {
            try? FileManager.default.removeItem(at: chunkURL)
        }
        chunkFrames = 0
        newFrames = 0
        overlapBuffers.removeAll()
        overlapFrames = 0
    }

    private func emitCurrentChunk(nextFormat: AVAudioFormat) throws {
        guard let completedURL = chunkURL else { return }
        chunkFile?.close()
        chunkFile = nil
        chunkURL = nil
        onChunk(completedURL)
        try startChunk(format: nextFormat, includingOverlap: true)
    }

    private func startChunk(
        format: AVAudioFormat,
        includingOverlap: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        sequence += 1
        let url = directory.appendingPathComponent("live-\(sequence).wav")
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        chunkFile = file
        chunkURL = url
        chunkFrames = 0
        newFrames = 0
        if includingOverlap {
            for buffer in overlapBuffers {
                try file.write(from: buffer)
                chunkFrames += AVAudioFramePosition(buffer.frameLength)
            }
        }
    }

    private func retainForOverlap(_ buffer: AVAudioPCMBuffer) {
        guard overlapDuration > 0 else {
            overlapBuffers.removeAll()
            overlapFrames = 0
            return
        }
        guard let copiedBuffer = Self.copy(buffer) else { return }
        overlapBuffers.append(copiedBuffer)
        overlapFrames += AVAudioFramePosition(copiedBuffer.frameLength)
        let targetFrames = AVAudioFramePosition(buffer.format.sampleRate * overlapDuration)
        while overlapFrames > targetFrames,
              overlapBuffers.count > 1
        {
            overlapFrames -= AVAudioFramePosition(overlapBuffers.removeFirst().frameLength)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let source = sourceBuffers[index].mData,
                  let destination = destinationBuffers[index].mData
            else {
                return nil
            }
            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }
}
