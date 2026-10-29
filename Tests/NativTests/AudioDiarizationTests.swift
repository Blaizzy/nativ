import Foundation
import XCTest
@testable import NativServerKit

@MainActor
final class AudioDiarizationTests: XCTestCase {
    func testTextOnlyModelReusesDiarizationAndTranscribesEachSpanOnce() async throws {
        let audio = try fallbackAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        var diarizations = 0
        var progress: [Double] = []
        let result = try await MeetingDiarizer.transcribe(audio, client: fallbackClient("fallback"),
            model: "selected-text-only-model") {
            diarizations += 1
        } segmentFinished: { progress.append($0) }
        let turns = try XCTUnwrap(result.diarization.transcriptSegments)
        XCTAssertEqual(diarizations, 1, "Fallback must reuse completed speaker detection")
        XCTAssertEqual(turns.map(\.start), [0.5, 1.5, 2.5, 32.5])
        XCTAssertEqual(turns.map(\.end), [1.5, 2.5, 32.5, 35])
        XCTAssertEqual(turns.map(\.speakers), [[7], [2, 7], [7], [7]])
        XCTAssertEqual(turns.map(\.text), ["0:16000", "1:16000", "2:480000", "32:40000"])
        XCTAssertEqual(result.text, turns.map(\.text).joined(separator: " "))
        XCTAssertEqual(result.diarization.revision, "fixture-revision")
        XCTAssertTrue(result.diarization.speakerTranscript?.contains("Speaker 3 + Speaker 8: 1:16000") == true)
        XCTAssertEqual(progress, [1, 1.5, 2.5, 32.5, 35], "Earlier streamed text must not be duplicated in the saved fallback result")
    }

    func testTextOnlyFallbackSkipsEmptyTranscriptsAndPropagatesOtherFailures() async throws {
        let audio = try fallbackAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let result = try await MeetingDiarizer.transcribe(audio, client: fallbackClient("empty-span"),
            model: "selected-text-only-model")
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.start), [0.5, 2.5, 32.5])
        for host in ["unrelated-error", "span-error", "invalid-timings"] {
            do {
                _ = try await MeetingDiarizer.transcribe(audio, client: fallbackClient(host), model: "selected-text-only-model")
                XCTFail("\(host) must not produce a completed transcript")
            } catch NativAudioAnalysisError.httpStatus(let status, let message) {
                XCTAssertEqual(host, "unrelated-error")
                XCTAssertEqual(status, 500)
                XCTAssertEqual(message, "Model execution failed")
            } catch NativAudioTranscriptionError.httpStatus(let status, _) {
                XCTAssertEqual(host, "span-error")
                XCTAssertEqual(status, 503)
            } catch MeetingDiarizationError.invalidOutput {
                XCTAssertEqual(host, "invalid-timings")
            }
        }
    }

    func testTextOnlyFallbackHonorsCancellationBetweenSpans() async throws {
        let audio = try fallbackAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let task = Task {
            try await MeetingDiarizer.transcribe(audio, client: fallbackClient("cancel"),
                model: "selected-text-only-model", segmentFinished: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must discard incomplete transcription")
        } catch is CancellationError {}
    }

    func testTextOnlyModelWithRealServer() async throws {
        guard let path = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_FALLBACK_AUDIO"],
              let model = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_FALLBACK_MODEL"] else {
            throw XCTSkip("Set NATIV_DIARIZATION_FALLBACK_AUDIO and NATIV_DIARIZATION_FALLBACK_MODEL for real-model fallback validation.")
        }
        let client = NativAudioClient(baseURL: URL(string: ProcessInfo.processInfo.environment["NATIV_AUDIO_TEST_SERVER"] ?? "http://127.0.0.1:8080")!)
        let result = try await MeetingDiarizer.transcribe(URL(fileURLWithPath: path), client: client, model: model)
        let turns = try XCTUnwrap(result.diarization.transcriptSegments)
        let chunks = try result.diarization.transcriptionWindows()
        XCTAssertFalse(turns.isEmpty)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(turns.allSatisfy { turn in
            chunks.contains { $0.start == turn.start && $0.end == turn.end && $0.speakers == turn.speakers }
        }, "Text-only ASR must retain the diarizer's speaker windows rather than invent word timestamps")
        if let output = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_TEST_OUTPUT"] {
            try result.diarization.speakerTranscript?.write(toFile: output, atomically: true, encoding: .utf8)
            try JSONEncoder().encode(result.diarization).write(to: URL(fileURLWithPath: output + ".json"))
        }
    }

    private func fallbackClient(_ host: String) -> NativAudioClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpanTranscriptionURLProtocol.self]
        return NativAudioClient(baseURL: URL(string: "http://\(host)")!, sessionConfiguration: configuration)
    }

    private func fallbackAudio() throws -> URL {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let samples = (0..<(36 * 16000)).map { Float($0 / 16000) / 100 }
        try VoiceWakeWordAudio(samples: samples).wavData.write(to: audio)
        return audio
    }

    func testTextOnlyWindowsKeepBriefPausesWithinTheSameSpeaker() throws {
        let spans: [(Double, Double)] = [
            (0.05, 1.55), (1.87, 2.37), (3.03, 5.63), (5.94, 7.53),
            (8.08, 10.78), (10.97, 18.42), (19.04, 22.63), (23.14, 23.78),
            (24.38, 28.57), (28.92, 29.02), (29.39, 34),
        ]
        let value = AudioDiarization(modelID: "model", revision: nil, segments:
            spans.map { .init(start: $0.0, end: $0.1, speaker: 0) })
        XCTAssertEqual(try value.transcriptionWindows(), [
            .init(start: 0.05, end: 29.02, speakers: [0]),
            .init(start: 29.39, end: 34, speakers: [0]),
        ])
        XCTAssertEqual(try value.transcriptionChunks().count, spans.count,
            "Speaker embeddings and saved legacy transcript timing must retain the original speech intervals")
    }

    func testTextOnlyWindowsRespectSpeakerChangesOverlapAndLongSilence() throws {
        let value = AudioDiarization(modelID: "model", revision: nil, segments: [
            .init(start: 0, end: 3, speaker: 0), .init(start: 3.5, end: 7, speaker: 1),
            .init(start: 5, end: 10, speaker: 0), .init(start: 14, end: 15, speaker: 0),
        ])
        XCTAssertEqual(try value.transcriptionWindows(), [
            .init(start: 0, end: 3, speakers: [0]), .init(start: 3.5, end: 5, speakers: [1]),
            .init(start: 5, end: 7, speakers: [0, 1]), .init(start: 7, end: 10, speakers: [0]),
            .init(start: 14, end: 15, speakers: [0]),
        ])
        for gap in [-1.0, .infinity, .nan] {
            XCTAssertThrowsError(try value.transcriptionWindows(maximumSilenceGap: gap))
        }
    }

    func testBriefOverlapsRetainSentenceContextAndAllSpeakerLabels() throws {
        let value = AudioDiarization(modelID: "model", revision: nil, segments: [
            .init(start: 58.11, end: 63.36, speaker: 0),
            .init(start: 61.75, end: 62.06, speaker: 1),
            .init(start: 64.54, end: 68.81, speaker: 1),
        ])
        XCTAssertEqual(try value.transcriptionWindows(), [
            .init(start: 58.11, end: 63.36, speakers: [0, 1]),
            .init(start: 64.54, end: 68.81, speakers: [1]),
        ])
        XCTAssertEqual(try value.transcriptionChunks().count, 4)
    }

    func testBriefExchangesDoNotExceedWindowLimitOrCrossLongSilence() throws {
        let value = AudioDiarization(modelID: "model", revision: nil, segments: [
            .init(start: 0, end: 30, speaker: 0), .init(start: 30, end: 30.2, speaker: 1),
            .init(start: 30.2, end: 33, speaker: 0), .init(start: 40, end: 40.5, speaker: 1),
        ])
        XCTAssertEqual(try value.transcriptionWindows(), [
            .init(start: 0, end: 30, speakers: [0]), .init(start: 30, end: 33, speakers: [0, 1]),
            .init(start: 40, end: 40.5, speakers: [1]),
        ])
    }

    func testLinkedVoicesBecomeOneParticipantWithoutChangingWordsOrTiming() throws {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0),
            .init(start: 2, end: 4, speaker: 1),
            .init(start: 3, end: 5, speaker: 2),
            .init(start: 6, end: 8, speaker: 3),
        ], transcriptSegments: [
            .init(start: 0, end: 2, speakers: [0], text: "Hello"),
            .init(start: 2, end: 3, speakers: [1], text: "Hi"),
            .init(start: 3, end: 4, speakers: [1, 2], text: "Still me"),
            .init(start: 4, end: 5, speakers: [2], text: "Another passage"),
            .init(start: 6, end: 8, speakers: [3], text: "A different person"),
        ], speakerNames: ["0": "Jordan", "1": "Me", "2": "Me", "3": "Me"],
           speakerProfileIDs: ["0": "nnenna", "1": "me", "2": "me", "3": "different-profile"])

        let grouped = original.groupedByProfile
        XCTAssertEqual(grouped.speakerIDs, [0, 1, 3], "Identity is the profile ID, not its display name")
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.speakers), [[0], [1], [1], [1], [3]])
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.text), original.resolvedTranscriptSegments.map(\.text))
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.start), original.resolvedTranscriptSegments.map(\.start))
        XCTAssertEqual(grouped.resolvedTranscriptSegments.map(\.end), original.resolvedTranscriptSegments.map(\.end))
        XCTAssertTrue(original.formattedTranscript?.contains("[00:03] Me: Still me") == true)
        XCTAssertFalse(original.formattedTranscript?.contains("Me + Me") == true)
        XCTAssertEqual(grouped.groupedByProfile, grouped)
        XCTAssertEqual(original.speakerIDs, [0, 1, 2, 3])
        XCTAssertEqual(try JSONDecoder().decode(AudioDiarization.self, from: JSONEncoder().encode(original)), original)
        let merged = try original.mergingSpeakers([1, 2], into: 1)
        XCTAssertEqual(merged.speakerIDs, [0, 1, 3])
        XCTAssertEqual(merged.transcriptSegments, grouped.transcriptSegments)
        XCTAssertNil(merged.speakerProfileIDs?["2"])
        XCTAssertNil(merged.speakerNames?["2"])
        XCTAssertFalse(merged.speakerTranscript?.contains("Speaker 3") == true)
        XCTAssertEqual(try JSONDecoder().decode(AudioDiarization.self, from: JSONEncoder().encode(merged)), merged)
    }

    func testMatchingLabelsWithoutAProfileStaySeparate() {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0), .init(start: 2, end: 4, speaker: 1),
        ], speakerNames: ["0": "Alex", "1": "Alex"])
        XCTAssertEqual(original.groupedByProfile, original)
    }

    func testLegacyTranscriptIsRecoveredBeforeGroupingLinkedVoices() throws {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0), .init(start: 2, end: 4, speaker: 1),
        ], speakerTranscript: "[00:00] Speaker 1: Hello\n\n[00:02] Speaker 2: Again",
           speakerNames: ["0": "Me", "1": "Me"], speakerProfileIDs: ["0": "me", "1": "me"])
        XCTAssertEqual(original.groupedByProfile.resolvedTranscriptSegments, [
            .init(start: 0, end: 2, speakers: [0], text: "Hello"),
            .init(start: 2, end: 4, speakers: [0], text: "Again"),
        ])
        XCTAssertEqual(original.formattedTranscript, "[00:00] Me: Hello\n\n[00:02] Me: Again")
        XCTAssertNil(original.transcriptSegments)
        XCTAssertEqual(try original.mergingSpeakers([0, 1], into: 0).transcriptSegments,
                       original.groupedByProfile.transcriptSegments)
    }

    func testUnrecoverableLegacyTranscriptCannotBeMerged() {
        let original = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 2, speaker: 0), .init(start: 2, end: 4, speaker: 1),
        ], speakerTranscript: "Saved text in an unknown legacy format")
        XCTAssertThrowsError(try original.mergingSpeakers([0, 1], into: 0))
    }

    func testServerWithRealModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_TEST_AUDIO"] else {
            throw XCTSkip("Set NATIV_DIARIZATION_TEST_AUDIO to NVIDIA's eight-voice sample WAV.")
        }
        var diarizationFinished = false
        var transcribedChunks = 0
        let client = NativAudioClient(baseURL: URL(string: ProcessInfo.processInfo.environment["NATIV_AUDIO_TEST_SERVER"] ?? "http://127.0.0.1:8080")!)
        let result = try await MeetingDiarizer.transcribe(URL(fileURLWithPath: path), client: client,
            model: MeetingDiarizer.defaultTranscriptionModelID) {
            diarizationFinished = true
        } segmentFinished: { _ in
            XCTAssertTrue(diarizationFinished, "No transcript may arrive before full-recording diarization completes")
            transcribedChunks += 1
        }
        XCTAssertEqual(result.diarization.modelID, MeetingDiarizer.defaultModelID)
        XCTAssertNil(result.diarization.revision)
        XCTAssertEqual(Set(result.diarization.segments.map(\.speaker)), Set(0..<8))
        XCTAssertGreaterThan(result.diarization.segments.map(\.end).max() ?? 0, 90)
        XCTAssertGreaterThan(transcribedChunks, 3)
        XCTAssertFalse(result.text.isEmpty)
        let text = try XCTUnwrap(result.diarization.speakerTranscript)
        for speaker in 1...8 { XCTAssertTrue(text.contains("Speaker \(speaker)")) }
        if let output = ProcessInfo.processInfo.environment["NATIV_DIARIZATION_TEST_OUTPUT"] {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    func testCancelledAnalysisDoesNotProduceResult() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingDiarizer.transcribe(URL(fileURLWithPath: "/nonexistent.wav"), client: NativAudioClient(baseURL: URL(string: "http://127.0.0.1:1")!), model: MeetingDiarizer.defaultTranscriptionModelID)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled diarization must not return a result")
        } catch is CancellationError {}
    }

    func testLongTurnsKeepGlobalSpeakerIDsAndAbsoluteTime() throws {
        let result = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 65, speaker: 7),
            .init(start: 3600, end: 3603, speaker: 2),
            .init(start: 7200, end: 7232, speaker: 7),
        ])
        let chunks = try result.transcriptionChunks()
        XCTAssertEqual(chunks.map(\.start), [0, 30, 60, 3600, 7200, 7230])
        XCTAssertEqual(chunks.map(\.end), [30, 60, 65, 3603, 7230, 7232])
        XCTAssertEqual(chunks.map(\.speakers), [[7], [7], [7], [2], [7], [7]])
        XCTAssertEqual(chunks[4].labeled("Still the same voice"), "[120:00] Speaker 8: Still the same voice")
    }

    func testOverlapIsTranscribedOnceAndSilenceIsOmitted() throws {
        let result = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 2, end: 5, speaker: 1),
            .init(start: 1, end: 3, speaker: 0),
            .init(start: 0, end: 4, speaker: 0),
            .init(start: 100, end: 101, speaker: 0),
        ])
        XCTAssertEqual(try result.transcriptionChunks(), [
            .init(start: 0, end: 2, speakers: [0]),
            .init(start: 2, end: 4, speakers: [0, 1]),
            .init(start: 4, end: 5, speakers: [1]),
            .init(start: 100, end: 101, speakers: [0]),
        ])
    }

    func testStreamBoundaryRoundingDoesNotInventTinyOverlaps() throws {
        let result = AudioDiarization(modelID: "model", revision: "test", segments: [
            .init(start: 0, end: 30.000000000000004, speaker: 0),
            .init(start: 30, end: 31, speaker: 1),
        ])
        XCTAssertEqual(try result.transcriptionChunks(), [
            .init(start: 0, end: 30, speakers: [0]), .init(start: 30, end: 31, speakers: [1]),
        ])
    }

    func testRejectsInvalidSpeakerOutput() {
        for segment: AudioDiarization.Segment in [
            .init(start: -1, end: 1, speaker: 0), .init(start: 0, end: .infinity, speaker: 0),
            .init(start: 0, end: 1, speaker: 8), .init(start: 1, end: 0, speaker: 0),
        ] {
            XCTAssertThrowsError(try AudioDiarization(modelID: "model", revision: "test", segments: [segment]).transcriptionChunks())
        }
    }

    func testLegacyTranscriptRecoversExactTimesAcrossHoursAndSkippedChunks() throws {
        let value = AudioDiarization(modelID: "test", revision: "test", segments: [
            .init(start: 0.25, end: 1.75, speaker: 7),
            .init(start: 2, end: 3, speaker: 0), // ASR returned no words.
            .init(start: 7200.25, end: 7201.75, speaker: 7),
            .init(start: 7200.25, end: 7201.75, speaker: 1),
        ], speakerTranscript: "[00:00] Speaker 8: Hello\n\n[120:00] Speaker 2 + Speaker 8: Together")
        XCTAssertEqual(value.resolvedTranscriptSegments, [
            .init(start: 0.25, end: 1.75, speakers: [7], text: "Hello"),
            .init(start: 7200.25, end: 7201.75, speakers: [1, 7], text: "Together"),
        ])
        var renamed = value
        renamed.speakerNames = ["7": "Casey"]
        XCTAssertEqual(renamed.formattedTranscript, "[00:00] Casey: Hello\n\n[120:00] Speaker 2 + Casey: Together")
        renamed.speakerTranscript = "Unexpected legacy text"
        XCTAssertEqual(renamed.formattedTranscript, "Unexpected legacy text")
        XCTAssertTrue(renamed.resolvedTranscriptSegments.isEmpty)
    }

    func testServerTranscriptPreservesGlobalIDsOverlapUnknownSpeechAndAbsoluteTime() throws {
        let response = try serverResponse(segments: """
            [{"id":"0","start":0.25,"end":1,"speaker":"A","text":"Hello"},
             {"id":"1","start":3600.25,"end":3601,"speaker":"B","speakers":["B","A"],"text":"Together"},
             {"id":"2","start":7200.25,"end":7201,"speaker":"unknown","text":"Unassigned"},
             {"id":"3","start":7202,"end":7203,"speaker":"A","text":"Again"}]
            """)
        let result = try MeetingDiarizer.Transcription(response)
        XCTAssertEqual(result.text, response.text)
        XCTAssertNil(result.diarization.revision)
        XCTAssertEqual(result.diarization.speakerIDs, [2, 7])
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.speakers), [[7], [2, 7], [], [7]])
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.start), response.segments.map(\.start))
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.end), response.segments.map(\.end))
        XCTAssertEqual(result.diarization.transcriptSegments?.map(\.text), response.segments.map(\.text))
        XCTAssertEqual(result.diarization.speakerTranscript,
            "[00:00] Speaker 8: Hello\n\n[60:00] Speaker 3 + Speaker 8: Together\n\n[120:00] Unassigned speaker: Unassigned\n\n[120:02] Speaker 8: Again")
    }

    func testServerTranscriptRejectsWrongModelMissingIDsAndUnmappedLabels() throws {
        let segment = #"[{"id":"0","start":0,"end":1,"speaker":"A","text":"Hello"}]"#
        for (model, ids) in [("wrong", #"{"A":7}"#), (MeetingDiarizer.defaultModelID, "null"),
                             (MeetingDiarizer.defaultModelID, #"{"B":2}"#)] {
            let response = try serverResponse(segments: segment, model: model, ids: ids)
            XCTAssertThrowsError(try MeetingDiarizer.Transcription(response))
        }
    }

    private func serverResponse(segments: String, model: String = MeetingDiarizer.defaultModelID,
                                ids: String = #"{"A":7,"B":2}"#) throws -> NativDiarizedTranscription {
        let detected = try JSONDecoder().decode(NativAudioDiarization.self, from: Data("""
            {"model":"\(model)","speaker_ids":\(ids),"segments":[
             {"start":0,"end":7203,"speaker":7},{"start":3600,"end":3601,"speaker":2}]}
            """.utf8))
        return NativDiarizedTranscription(text: "Hello Together Unassigned Again", duration: 7203,
            segments: try JSONDecoder().decode([NativDiarizedSegment].self, from: Data(segments.utf8)),
            diarization: detected)
    }

}

private final class SpanTranscriptionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions", "Do not run diarization a second time")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertNotNil(body.range(of: Data("name=\"model\"\r\n\r\nselected-text-only-model\r\n".utf8)))
            let host = request.url?.host
            if request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
                let end = host == "invalid-timings" ? 1e30 : 33.5
                let detected = """
                    {"model":"\(MeetingDiarizer.defaultModelID)","revision":"fixture-revision","speaker_ids":{"A":7,"B":2},
                     "segments":[{"start":0.5,"end":\(end),"speaker":7},{"start":1.5,"end":2.5,"speaker":2},{"start":34,"end":35,"speaker":7}]}
                    """.replacingOccurrences(of: "\n", with: "")
                let message = host == "unrelated-error" ? "Model execution failed"
                    : "diarized_json requires a model with word timestamps (for example Parakeet)"
                var events = ["{\"type\":\"diarization.completed\",\"diarization\":\(detected)}"]
                if host == "fallback" {
                    events.append(#"{"type":"transcript.text.segment","id":"early","start":0.5,"end":1,"text":"Earlier partial text","speaker":"A"}"#)
                }
                events.append("{\"type\":\"error\",\"error\":{\"message\":\"\(message)\"}}")
                respond(Data(events.map { "data: \($0)\n\n" }.joined().utf8), type: "text/event-stream")
            } else {
                XCTAssertFalse(["unrelated-error", "invalid-timings"].contains(host ?? ""))
                XCTAssertNotNil(body.range(of: Data("name=\"response_format\"\r\n\r\njson\r\n".utf8)))
                let start = try XCTUnwrap(body.range(of: Data("RIFF".utf8))).lowerBound
                func word(_ offset: Int) -> UInt32 {
                    body.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: start + offset, as: UInt32.self)) }
                }
                XCTAssertEqual(word(24), 16000)
                XCTAssertEqual(word(20), 0x00010003, "Mono IEEE float WAV")
                let sampleCount = Int(word(40)) / 4
                XCTAssertLessThanOrEqual(sampleCount, 30 * 16000)
                let firstSecond = Int((Float(bitPattern: word(44)) * 100).rounded())
                if host == "cancel" { XCTAssertEqual(firstSecond, 0, "No later span may be uploaded after cancellation") }
                let text = host == "empty-span" && firstSecond == 1 ? "" : "\(firstSecond):\(sampleCount)"
                respond(try JSONSerialization.data(withJSONObject: ["text": text]),
                    status: host == "span-error" ? 503 : 200, type: "application/json")
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func respond(_ data: Data, status: Int = 200, type: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class AudioDiarizationStorageTests: XCTestCase {
    func testSpeakerNamesPersistAndAffectExportWithoutChangingWordsOrIDs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AudioAnalyticsStore(storageURL: url)
        let diarization = AudioDiarization(modelID: "model", revision: "rev", segments: [
            .init(start: 3600.5, end: 3602, speaker: 2),
        ], speakerTranscript: "[60:00] Speaker 3: Hello")
        store.upsertTranscription(recordingURL: url.deletingPathExtension().appendingPathExtension("wav"),
                                  transcript: "Hello", durationSeconds: 3602, modelID: "stt", applicationName: nil,
                                  kind: .meeting, summary: "Summary", diarization: diarization)
        let id = try XCTUnwrap(store.records.first?.id)
        store.updateSpeakerName("  Casey\nTaylor  ", speakerID: 2, for: id)
        let record = try XCTUnwrap(AudioAnalyticsStore(storageURL: url).records.first)
        XCTAssertEqual(record.diarization?.speakerName(2), "Casey Taylor")
        XCTAssertEqual(record.diarization?.segments, diarization.segments)
        XCTAssertEqual(record.diarization?.transcriptSegments?.first?.start, 3600.5)
        XCTAssertEqual(record.transcript, "Hello")
        XCTAssertEqual(record.displayTranscript, "[60:00] Casey Taylor: Hello")
        let exported = String(decoding: try AudioRecordExport(record: record).data(format: .text), as: UTF8.self)
        XCTAssertTrue(exported.contains("[60:00] Casey Taylor: Hello"))
        store.updateSpeakerName("", speakerID: 2, for: id)
        XCTAssertEqual(AudioAnalyticsStore(storageURL: url).records.first?.displayTranscript, "[60:00] Speaker 3: Hello")
    }
    func testLegacyRecordsAndSpeakerMetadataSurviveEditsAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("records.json")
        let audio = directory.appendingPathComponent("meeting.wav")
        let store = AudioAnalyticsStore(storageURL: storage)
        store.upsertTranscription(recordingURL: audio, transcript: "Hello", durationSeconds: 1, modelID: "stt", applicationName: nil, kind: .meeting)
        XCTAssertEqual(AudioAnalyticsStore(storageURL: storage).records.first?.displayTranscript, "Hello")
        let speakers = AudioDiarization(modelID: MeetingDiarizer.defaultModelID, revision: "test", segments: [.init(start: 0, end: 1, speaker: 0)], speakerTranscript: "[00:00] Speaker 1: Hello")
        store.upsertTranscription(recordingURL: audio, transcript: "Hello", durationSeconds: 1, modelID: "stt", applicationName: nil, kind: .meeting, diarization: speakers)
        store.updateTitle("Team meeting", for: "meeting")
        store.updateSummary("Summary", for: "meeting")
        let record = try XCTUnwrap(AudioAnalyticsStore(storageURL: storage).records.first)
        XCTAssertEqual(record.diarization, speakers)
        XCTAssertEqual(record.displayTranscript, speakers.speakerTranscript)
        XCTAssertEqual(record.wordCount, 1)
        // A failed retry must not retain speaker labels from an older transcript.
        store.upsertTranscription(recordingURL: audio, transcript: "New text", durationSeconds: 1, modelID: "stt", applicationName: nil)
        XCTAssertNil(store.records.first?.diarization)
    }
}
