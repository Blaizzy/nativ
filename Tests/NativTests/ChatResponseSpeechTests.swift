import Foundation
import XCTest
@testable import NativServerKit

final class NativAudioSpeechClientTests: XCTestCase {
    func testSpeechRequestUsesConfiguredServerModelAndAuthorization() throws {
        let client = NativAudioClient(
            baseURL: try XCTUnwrap(URL(string: "http://speech-runtime.local:49152")),
            apiKey: "test-token",
            timeout: 123
        )
        let text = "A response with \"quotes\", a newline\nκαι ελληνικά."
        let request = try client.makeSpeechURLRequest(text: text, model: "local-owner/tts")

        XCTAssertEqual(request.url?.absoluteString, "http://speech-runtime.local:49152/v1/audio/speech")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 123)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/wav")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, text)
        XCTAssertEqual(body["model"] as? String, "local-owner/tts")
        XCTAssertEqual(body["response_format"] as? String, "wav")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testSynthesisReturnsAudioData() async throws {
        let data = try await client(host: "success").synthesize(text: "Hello", model: "tts")
        XCTAssertEqual(data, Data("test-audio".utf8))
    }

    func testSynthesisSurfacesServerError() async throws {
        do {
            _ = try await client(host: "failure").synthesize(text: "Hello", model: "tts")
            XCTFail("Expected the server error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Model could not be loaded"))
        }
    }

    func testSynthesisRejectsEmptyAudio() async throws {
        do {
            _ = try await client(host: "empty").synthesize(text: "Hello", model: "tts")
            XCTFail("Expected an empty audio error")
        } catch NativAudioSpeechError.emptyAudio {
        }
    }

    private func client(host: String) throws -> NativAudioClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeechURLProtocol.self]
        return NativAudioClient(
            baseURL: try XCTUnwrap(URL(string: "http://\(host)")),
            sessionConfiguration: configuration
        )
    }
}

private final class SpeechURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let failed = request.url?.host == "failure"
        let data = failed ? Data(#"{"detail":"Model could not be loaded"}"#.utf8)
            : request.url?.host == "empty" ? Data() : Data("test-audio".utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: failed ? 500 : 200,
            httpVersion: nil, headerFields: ["Content-Type": failed ? "application/json" : "audio/wav"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class ChatResponseSpeechTests: XCTestCase {
    private var settings: NativSettings { NativSettings(textToSpeechModelID: "local-owner/tts") }

    func testResponseIsSynthesizedAndPlaybackCompletionResetsState() async {
        let played = expectation(description: "Audio played")
        let playback = TestSpeechPlayback(onPlay: { played.fulfill() })
        var receivedText: String?
        var receivedSettings: NativSettings?
        let speech = ChatResponseSpeech(synthesize: { text, settings in
            receivedText = text
            receivedSettings = settings
            return Data([1, 2, 3])
        }, makePlayback: { data in
            XCTAssertEqual(data, Data([1, 2, 3]))
            return playback
        })
        let id = UUID()
        speech.toggle(messageID: id, text: "The response", settings: settings)
        XCTAssertEqual(speech.phase, .generating)
        await fulfillment(of: [played], timeout: 2)
        XCTAssertEqual(receivedText, "The response")
        XCTAssertEqual(receivedSettings?.textToSpeechModelID, "local-owner/tts")
        XCTAssertEqual(speech.messageID, id)
        XCTAssertEqual(speech.phase, .playing)
        playback.onFinish?(nil)
        XCTAssertNil(speech.messageID)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNil(speech.errorMessage)
    }

    func testStoppingPendingSynthesisNeverStartsPlayback() async {
        let started = expectation(description: "Synthesis started")
        let returned = expectation(description: "Synthesis returned")
        var continuation: CheckedContinuation<Data, Never>?
        var playbackCount = 0
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            let data = await withCheckedContinuation { continuation = $0; started.fulfill() }
            defer { returned.fulfill() }
            return data
        }, makePlayback: { _ in playbackCount += 1; return TestSpeechPlayback() })
        let id = UUID()
        speech.toggle(messageID: id, text: "Response", settings: settings)
        await fulfillment(of: [started], timeout: 2)
        speech.toggle(messageID: id, text: "Response", settings: settings)
        continuation?.resume(returning: Data([1]))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(playbackCount, 0)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNil(speech.errorMessage)
    }

    func testSelectingAnotherResponseDiscardsOlderSynthesis() async {
        let firstStarted = expectation(description: "First started")
        let firstReturned = expectation(description: "First returned")
        let secondPlayed = expectation(description: "Second played")
        var firstContinuation: CheckedContinuation<Data, Never>?
        var playedData: [Data] = []
        let playback = TestSpeechPlayback(onPlay: { secondPlayed.fulfill() })
        let speech = ChatResponseSpeech(synthesize: { text, _ in
            if text == "First" {
                let data = await withCheckedContinuation { firstContinuation = $0; firstStarted.fulfill() }
                defer { firstReturned.fulfill() }
                return data
            }
            return Data([2])
        }, makePlayback: { data in playedData.append(data); return playback })
        speech.toggle(messageID: UUID(), text: "First", settings: settings)
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondID = UUID()
        speech.toggle(messageID: secondID, text: "Second", settings: settings)
        await fulfillment(of: [secondPlayed], timeout: 2)
        firstContinuation?.resume(returning: Data([1]))
        await fulfillment(of: [firstReturned], timeout: 2)
        XCTAssertEqual(playedData, [Data([2])])
        XCTAssertEqual(speech.messageID, secondID)
        XCTAssertEqual(speech.phase, .playing)
        speech.stop()
    }

    func testSwitchingPlaybackStopsPreviousPlayerAndIgnoresItsCompletion() async {
        let firstPlayed = expectation(description: "First played")
        let secondPlayed = expectation(description: "Second played")
        let first = TestSpeechPlayback(onPlay: { firstPlayed.fulfill() })
        let second = TestSpeechPlayback(onPlay: { secondPlayed.fulfill() })
        let speech = ChatResponseSpeech(synthesize: { text, _ in Data(text.utf8) },
                                        makePlayback: { $0 == Data("First".utf8) ? first : second })
        speech.toggle(messageID: UUID(), text: "First", settings: settings)
        await fulfillment(of: [firstPlayed], timeout: 2)
        let oldCompletion = first.onFinish
        let secondID = UUID()
        speech.toggle(messageID: secondID, text: "Second", settings: settings)
        await fulfillment(of: [secondPlayed], timeout: 2)
        XCTAssertEqual(first.stopCount, 1)
        oldCompletion?("Old decoding error")
        XCTAssertEqual(speech.messageID, secondID)
        XCTAssertNil(speech.errorMessage)
        speech.toggle(messageID: secondID, text: "Second", settings: settings)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(speech.phase, .idle)
    }

    func testFailureCanBeRetriedAndPlaybackErrorsResetState() async {
        let failed = expectation(description: "Synthesis failed")
        let played = expectation(description: "Retry played")
        var attempt = 0
        let playback = TestSpeechPlayback(onPlay: { played.fulfill() })
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            attempt += 1
            if attempt == 1 {
                defer { failed.fulfill() }
                throw URLError(.cannotConnectToHost)
            }
            return Data([1])
        }, makePlayback: { _ in playback })
        let id = UUID()
        speech.toggle(messageID: id, text: "Response", settings: settings)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNotNil(speech.errorMessage)
        speech.toggle(messageID: id, text: "Response", settings: settings)
        await fulfillment(of: [played], timeout: 2)
        XCTAssertNil(speech.errorMessage)
        playback.onFinish?("Audio decoding failed")
        XCTAssertEqual(speech.errorMessage, "Audio decoding failed")
        XCTAssertEqual(speech.phase, .idle)
    }

    func testPlaybackRefusalSurfacesError() async {
        let attempted = expectation(description: "Playback attempted")
        let playback = TestSpeechPlayback(onPlay: { attempted.fulfill() }, canPlay: false)
        let speech = ChatResponseSpeech(synthesize: { _, _ in Data([1]) }, makePlayback: { _ in playback })
        speech.toggle(messageID: UUID(), text: "Response", settings: settings)
        await fulfillment(of: [attempted], timeout: 2)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNotNil(speech.errorMessage)
        XCTAssertEqual(playback.stopCount, 1)
    }

    func testInvalidAudioSurfacesNativePlayerError() async {
        let synthesized = expectation(description: "Invalid audio returned")
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            defer { synthesized.fulfill() }
            return Data("not audio".utf8)
        })
        speech.toggle(messageID: UUID(), text: "Response", settings: settings)
        await fulfillment(of: [synthesized], timeout: 2)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNil(speech.messageID)
        XCTAssertNotNil(speech.errorMessage)
    }

    func testMissingModelAndEmptyResponseDoNotGenerateAudio() {
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            XCTFail("Should not request synthesis")
            return Data()
        })
        speech.toggle(messageID: UUID(), text: "Response", settings: NativSettings())
        XCTAssertTrue(speech.errorMessage?.contains("text-to-speech model") == true)
        speech.toggle(messageID: UUID(), text: " \n ", settings: settings)
        XCTAssertNil(speech.errorMessage)
        XCTAssertEqual(speech.phase, .idle)
    }
}

@MainActor
private final class TestSpeechPlayback: ChatSpeechPlayback {
    var onFinish: ((String?) -> Void)?
    private let onPlay: () -> Void
    private let canPlay: Bool
    private(set) var stopCount = 0

    init(onPlay: @escaping () -> Void = {}, canPlay: Bool = true) {
        self.onPlay = onPlay
        self.canPlay = canPlay
    }

    func play() -> Bool { onPlay(); return canPlay }
    func stop() { stopCount += 1 }
}
