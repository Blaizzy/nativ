import AVFoundation
import Foundation
import XCTest

final class AudioFileImporterTests: XCTestCase {
    private func temporaryURL(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
    }

    private func makeBuffer(
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
                data[channel][frame] = Float(sin(phase) * 0.5)
            }
        }
        return buffer
    }

    private func makeWAV(
        seconds: Double,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2
    ) throws -> URL {
        let url = temporaryURL("wav")
        let buffer = try makeBuffer(seconds: seconds, sampleRate: sampleRate, channels: channels)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        if buffer.frameLength > 0 {
            try file.write(from: buffer)
        }
        return url
    }

    private func makeM4A(
        seconds: Double,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2
    ) throws -> URL {
        let url = temporaryURL("m4a")
        let buffer = try makeBuffer(seconds: seconds, sampleRate: sampleRate, channels: channels)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
            ]
        )
        try file.write(from: buffer)
        return url
    }

    private func makeFile(_ fileExtension: String, header: [UInt8]) throws -> URL {
        let url = temporaryURL(fileExtension)
        var bytes = header
        bytes.append(contentsOf: [UInt8](repeating: 0, count: max(0, 128 - bytes.count)))
        try Data(bytes).write(to: url)
        return url
    }

    private func oggBytes(codec: [UInt8]) -> [UInt8] {
        var bytes = Array("OggS".utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 22))
        bytes.append(1)
        bytes.append(UInt8(codec.count))
        bytes.append(contentsOf: codec)
        return bytes
    }

    func testPlanPassesThroughFormatsTheServerCanDecode() throws {
        let wav = try makeWAV(seconds: 0.1)
        let flac = try makeFile("flac", header: Array("fLaC".utf8))
        let tagged = try makeFile("mp3", header: Array("ID3".utf8) + [0x04, 0x00])
        let bare = try makeFile("mp3", header: [0xFF, 0xFB, 0x90, 0x00])
        let vorbis = try makeFile("ogg", header: oggBytes(codec: [0x01] + Array("vorbis".utf8)))

        XCTAssertEqual(AudioFileImporter.plan(for: wav), .passthrough(fileExtension: "wav"))
        XCTAssertEqual(AudioFileImporter.plan(for: flac), .passthrough(fileExtension: "flac"))
        XCTAssertEqual(AudioFileImporter.plan(for: tagged), .passthrough(fileExtension: "mp3"))
        XCTAssertEqual(AudioFileImporter.plan(for: bare), .passthrough(fileExtension: "mp3"))
        XCTAssertEqual(AudioFileImporter.plan(for: vorbis), .passthrough(fileExtension: "ogg"))
    }

    func testPlanTranscodesFormatsOnlyAVFoundationCanDecode() throws {
        let m4a = try makeM4A(seconds: 0.1)
        let caf = try makeFile("caf", header: Array("caff".utf8))
        let aiff = try makeFile("aiff", header: Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8))

        XCTAssertEqual(AudioFileImporter.plan(for: m4a), .transcode)
        XCTAssertEqual(AudioFileImporter.plan(for: caf), .transcode)
        XCTAssertEqual(AudioFileImporter.plan(for: aiff), .transcode)
    }

    func testPlanRejectsFormatsNeitherSideCanDecode() throws {
        let opus = try makeFile("opus", header: oggBytes(codec: Array("OpusHead".utf8)))
        let webm = try makeFile("webm", header: [0x1A, 0x45, 0xDF, 0xA3])

        XCTAssertEqual(AudioFileImporter.plan(for: opus), .reject(format: "Opus"))
        XCTAssertEqual(AudioFileImporter.plan(for: webm), .reject(format: "WebM"))
    }

    func testPlanRejectsOpusCarryingAnOggExtension() throws {
        let disguised = try makeFile("ogg", header: oggBytes(codec: Array("OpusHead".utf8)))
        XCTAssertEqual(
            AudioFileImporter.plan(for: disguised),
            .reject(format: "Opus"),
            "the .opus and .ogg extensions share one content type, so only the header can tell them apart"
        )
    }

    func testPlanFollowsContentRatherThanFileExtension() throws {
        let wav = try makeWAV(seconds: 0.1)
        let mislabelled = wav.deletingPathExtension().appendingPathExtension("m4a")
        try FileManager.default.moveItem(at: wav, to: mislabelled)
        let aac = try makeM4A(seconds: 0.1)
        let disguisedAAC = aac.deletingPathExtension().appendingPathExtension("wav")
        try FileManager.default.moveItem(at: aac, to: disguisedAAC)

        XCTAssertEqual(
            AudioFileImporter.plan(for: mislabelled),
            .passthrough(fileExtension: "wav"),
            "a WAV named .m4a is still readable server-side"
        )
        XCTAssertEqual(
            AudioFileImporter.plan(for: disguisedAAC),
            .transcode,
            "AAC named .wav would fail server-side, so it has to be transcoded"
        )
    }

    func testMissingFileIsUnreadableRatherThanRejected() async throws {
        let missing = URL(filePath: "/nonexistent/recording.opus")
        XCTAssertEqual(AudioFileImporter.plan(for: missing), .transcode)
        await assertImportFails(from: missing, with: .unreadable)
    }

    func testRejectedFormatFailsWithTheFormatName() async throws {
        let opus = try makeFile("opus", header: oggBytes(codec: Array("OpusHead".utf8)))
        await assertImportFails(from: opus, with: .unsupportedFormat("Opus"))
    }

    func testPassthroughCopiesWithoutReencoding() async throws {
        let source = try makeWAV(seconds: 0.25)
        let imported = try await AudioFileImporter().importFile(
            from: source,
            into: temporaryURL("import")
        )

        XCTAssertFalse(imported.wasTranscoded, "WAV is readable server-side, so it must not be re-encoded")
        XCTAssertEqual(imported.url.pathExtension, "wav")
        let copied = try AVAudioFile(forReading: imported.url)
        XCTAssertEqual(copied.fileFormat.sampleRate, 44_100, "passthrough must not resample")
        XCTAssertEqual(copied.fileFormat.channelCount, 2, "passthrough must not downmix")
        XCTAssertEqual(imported.duration, 0.25, accuracy: 0.01)
    }

    func testTranscodeProducesMonoTranscriptionAudio() async throws {
        let source = try makeM4A(seconds: 3, sampleRate: 44_100, channels: 2)
        let imported = try await AudioFileImporter().importFile(
            from: source,
            into: temporaryURL("import")
        )

        XCTAssertTrue(imported.wasTranscoded)
        XCTAssertEqual(imported.url.pathExtension, "wav")
        let output = try AVAudioFile(forReading: imported.url)
        XCTAssertEqual(output.fileFormat.sampleRate, AudioFileImporter.transcriptionSampleRate)
        XCTAssertEqual(output.fileFormat.channelCount, 1)
        XCTAssertEqual(
            Double(output.length) / output.fileFormat.sampleRate,
            3,
            accuracy: 0.05,
            "the resampled file must keep the original duration, not stop at the first chunk"
        )
    }

    func testTranscodePreservesAudioRatherThanWritingSilence() async throws {
        let source = try makeM4A(seconds: 0.5, sampleRate: 44_100, channels: 2)
        let imported = try await AudioFileImporter().importFile(
            from: source,
            into: temporaryURL("import")
        )

        let output = try AVAudioFile(forReading: imported.url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: output.processingFormat,
                frameCapacity: AVAudioFrameCount(output.length)
            )
        )
        try output.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        var peak: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[frame]))
        }
        XCTAssertGreaterThan(peak, 0.1, "a 440 Hz tone must survive the resample")
    }

    func testStagingFileIsNotLeftBehind() async throws {
        let source = try makeM4A(seconds: 0.2)
        let directory = temporaryURL("import")
        let imported = try await AudioFileImporter().importFile(from: source, into: directory)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, [imported.url.lastPathComponent])
    }

    func testDurationLimitMatchesTheDocumentedMaximum() {
        XCTAssertEqual(AudioFileImporter.maximumDuration, 50 * 60)
        XCTAssertEqual(AudioFileImporter.transcriptionSampleRate, 16_000)
    }

    func testEmptyAudioIsRejected() async throws {
        let source = try makeWAV(seconds: 0)
        await assertImportFails(from: source, with: .empty)
    }

    func testImportIsCancellable() async throws {
        let source = try makeM4A(seconds: 120)
        let directory = temporaryURL("import")

        let task = Task {
            try await AudioFileImporter().importFile(from: source, into: directory)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled import must not produce a file")
        } catch is CancellationError {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path),
                "cancellation must not leave a partial import behind"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func assertImportFails(
        from source: URL,
        with expected: AudioFileImportError
    ) async {
        do {
            _ = try await AudioFileImporter().importFile(
                from: source,
                into: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
            XCTFail("expected \(expected)")
        } catch let error as AudioFileImportError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
