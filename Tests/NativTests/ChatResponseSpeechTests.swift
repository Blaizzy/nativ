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
        let retried = expectation(description: "Retry played")
        var continuation: CheckedContinuation<Data, Never>?
        var playbackCount = 0
        var synthesisCount = 0
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            if synthesisCount > 1 { return Data([2]) }
            let data = await withCheckedContinuation { continuation = $0; started.fulfill() }
            defer { returned.fulfill() }
            return data
        }, makePlayback: { data in
            playbackCount += 1
            XCTAssertEqual(data, Data([2]))
            return TestSpeechPlayback(onPlay: { retried.fulfill() })
        })
        let id = UUID()
        speech.toggle(messageID: id, text: "Response", settings: settings)
        await fulfillment(of: [started], timeout: 2)
        speech.toggle(messageID: id, text: "Response", settings: settings)
        continuation?.resume(returning: Data([1]))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(playbackCount, 0)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNil(speech.errorMessage)
        speech.toggle(messageID: id, text: "Response", settings: settings)
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(synthesisCount, 2)
        speech.stop()
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

    func testReplayAfterCompletionAndStopReusesAudio() async {
        var synthesisCount = 0
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            return Data([1, 2, 3])
        }, makePlayback: { data in
            XCTAssertEqual(data, Data([1, 2, 3]))
            return playback
        })
        let id = UUID()
        await playResponse(speech, playback: playback, id: id)
        playback.onFinish?(nil)
        await playResponse(speech, playback: playback, id: id)
        speech.stop()
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, 1)
        speech.stop()
    }

    func testReplayExpiresFiveMinutesAfterGenerationWithoutExtendingOnCacheHit() async {
        var time = ContinuousClock.now
        var synthesisCount = 0
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            return Data([1])
        }, makePlayback: { _ in playback }, now: { time })
        let id = UUID()
        await playResponse(speech, playback: playback, id: id)
        time = time.advanced(by: .seconds(299))
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, 1)
        time = time.advanced(by: .seconds(1))
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, 2)
        speech.stop()
    }

    func testExpiredAudioIsReleasedWithoutAnotherPlaybackRequest() async {
        let released = expectation(description: "Expired audio buffer released")
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 1)
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
            return Data(bytesNoCopy: buffer, count: 1024, deallocator: .custom { buffer, _ in
                buffer.deallocate()
                released.fulfill()
            })
        }, makePlayback: { _ in playback }, cacheLifetime: .milliseconds(100))
        await playResponse(speech, playback: playback, id: UUID())
        speech.stop()
        await fulfillment(of: [released], timeout: 2)
        // Keep the controller alive throughout expiry, as it is while the transcript is visible.
        XCTAssertEqual(speech.phase, .idle)
    }

    func testCacheSeparatesResponseTextModelServerAndCredentials() async {
        var synthesisCount = 0
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            return Data([1])
        }, makePlayback: { _ in playback })
        let id = UUID()
        var otherModel = settings
        otherModel.textToSpeechModelID = "local-owner/other-tts"
        var otherServer = settings
        otherServer.serverPort += 1
        var otherCredentials = settings
        otherCredentials.serverAPIKey = "another-token"
        let requests: [(UUID, String, NativSettings)] = [
            (id, "Response", settings),
            (UUID(), "Response", settings),
            (id, "Edited response", settings),
            (id, "Response", otherModel),
            (id, "Response", otherServer),
            (id, "Response", otherCredentials),
        ]
        for (index, request) in requests.enumerated() {
            await playResponse(speech, playback: playback, id: request.0, text: request.1, settings: request.2)
            XCTAssertEqual(synthesisCount, index + 1)
        }
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, requests.count)
        speech.stop()
    }

    func testCacheEvictsLeastRecentlyPlayedAudioToStayWithinByteLimit() async {
        var synthesisCount = 0
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            return Data([1, 2])
        }, makePlayback: { _ in playback }, cacheByteLimit: 4)
        let first = UUID(), second = UUID(), third = UUID()
        for id in [first, second, first, third, first] {
            await playResponse(speech, playback: playback, id: id)
        }
        XCTAssertEqual(synthesisCount, 3)
        await playResponse(speech, playback: playback, id: second)
        XCTAssertEqual(synthesisCount, 4)
        speech.stop()
    }

    func testOversizedAudioPlaysWithoutBeingCached() async {
        var synthesisCount = 0
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            return Data([1, 2, 3])
        }, makePlayback: { _ in playback }, cacheByteLimit: 2)
        let id = UUID()
        await playResponse(speech, playback: playback, id: id)
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, 2)
        speech.stop()
    }

    func testPlaybackErrorEvictsCachedAudio() async {
        var synthesisCount = 0
        let playback = TestSpeechPlayback()
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            synthesisCount += 1
            return Data([1])
        }, makePlayback: { _ in playback })
        let id = UUID()
        await playResponse(speech, playback: playback, id: id)
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, 1)
        playback.onFinish?("Audio decoding failed")
        await playResponse(speech, playback: playback, id: id)
        XCTAssertEqual(synthesisCount, 2)
        XCTAssertNil(speech.errorMessage)
        speech.stop()
    }

    func testAutomaticSpeechDownloadsPhononAndReplaysWithoutPreparingServerAgain() async {
        let playback = TestSpeechPlayback()
        var steps: [String] = []
        var speech: ChatResponseSpeech!
        let preparation = ChatSpeechPreparation(
            resolveModel: { settings in
                XCTAssertNil(settings.textToSpeechModelID)
                steps.append("resolve")
                return .init(id: ChatSpeechPreparation.defaultModelID, isInstalled: false)
            },
            downloadModel: { selected, settings in
                XCTAssertEqual(selected.id, "nativ-community/phonon")
                XCTAssertEqual(settings.textToSpeechModelID, selected.id)
                XCTAssertEqual(speech.phase, .downloading)
                speech.updateDownloadProgress(0.5)
                XCTAssertEqual(speech.statusText, "Downloading voice… 50%")
                steps.append("download")
            },
            prepareServer: { _ in
                XCTAssertEqual(speech.phase, .startingServer)
                steps.append("server")
            }
        )
        speech = ChatResponseSpeech(synthesize: { _, settings in
            XCTAssertEqual(settings.textToSpeechModelID, "nativ-community/phonon")
            steps.append("synthesize")
            return Data([1])
        }, makePlayback: { _ in steps.append("play"); return playback })
        let id = UUID()
        await playResponse(speech, playback: playback, id: id, settings: NativSettings(), preparation: preparation)
        XCTAssertEqual(steps, ["resolve", "download", "server", "synthesize", "play"])
        steps.removeAll()
        // Cached playback does not need a server or even a model still present on disk.
        await playResponse(speech, playback: playback, id: id, settings: NativSettings(), preparation: preparation)
        XCTAssertEqual(steps, ["resolve", "play"])
        speech.stop()
        XCTAssertNil(speech.preparingModelID)
        XCTAssertNil(speech.downloadProgress)
    }

    func testAutomaticSpeechUsesInstalledModelWithoutDownloadingFallback() async {
        let playback = TestSpeechPlayback()
        let preparation = ChatSpeechPreparation(
            resolveModel: { _ in .init(id: "local-owner/installed-tts", isInstalled: true) },
            downloadModel: { _, _ in XCTFail("Installed voices should not download") },
            prepareServer: { _ in }
        )
        let speech = ChatResponseSpeech(synthesize: { _, settings in
            XCTAssertEqual(settings.textToSpeechModelID, "local-owner/installed-tts")
            return Data([1])
        }, makePlayback: { _ in playback })
        await playResponse(speech, playback: playback, id: UUID(), settings: NativSettings(), preparation: preparation)
        speech.stop()
    }

    func testCancellingDownloadPreventsServerStartupAndPlayback() async {
        let started = expectation(description: "Download started")
        let returned = expectation(description: "Download returned after cancellation")
        var continuation: CheckedContinuation<Void, Never>?
        let preparation = ChatSpeechPreparation(
            resolveModel: { _ in .init(id: ChatSpeechPreparation.defaultModelID, isInstalled: false) },
            downloadModel: { _, _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
                returned.fulfill()
            },
            prepareServer: { _ in XCTFail("Cancelled requests must not start a server") }
        )
        let speech = ChatResponseSpeech(synthesize: { _, _ in
            XCTFail("Cancelled download must not generate speech")
            return Data()
        })
        let id = UUID()
        speech.toggle(messageID: id, text: "Response", settings: NativSettings(), preparation: preparation)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(speech.phase, .downloading)
        speech.toggle(messageID: id, text: "Response", settings: NativSettings(), preparation: preparation)
        continuation?.resume()
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNil(speech.errorMessage)
    }

    func testPreparationFailureCanBeRetried() async {
        for failingStage in ["download", "server"] {
            let failed = expectation(description: "Preparation failed at \(failingStage)")
            var shouldFail = true
            let playback = TestSpeechPlayback()
            let preparation = ChatSpeechPreparation(
                resolveModel: { _ in .init(id: ChatSpeechPreparation.defaultModelID, isInstalled: false) },
                downloadModel: { _, _ in
                    if shouldFail && failingStage == "download" {
                        defer { failed.fulfill() }
                        throw URLError(.notConnectedToInternet)
                    }
                },
                prepareServer: { _ in
                    if shouldFail {
                        XCTAssertEqual(failingStage, "server", "Failed downloads must not start a server")
                        defer { failed.fulfill() }
                        throw URLError(.cannotConnectToHost)
                    }
                }
            )
            let speech = ChatResponseSpeech(synthesize: { _, _ in
                XCTAssertFalse(shouldFail)
                return Data([1])
            }, makePlayback: { _ in playback })
            let id = UUID()
            speech.toggle(messageID: id, text: "Response", settings: NativSettings(), preparation: preparation)
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(speech.phase, .idle)
            XCTAssertNotNil(speech.errorMessage)
            shouldFail = false
            await playResponse(speech, playback: playback, id: id, settings: NativSettings(), preparation: preparation)
            XCTAssertNil(speech.errorMessage)
            speech.stop()
        }
    }

    func testAutomaticSpeechDownloadsFallbackWhenCacheDoesNotExist() async {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
        let settings = NativSettings(modelSearchPath: cache.path)
        let playback = TestSpeechPlayback()
        var didDownload = false
        let preparation = ChatSpeechPreparation(
            resolveModel: ChatSpeechPreparation.resolveModel(for:),
            downloadModel: { selected, _ in
                XCTAssertEqual(selected, .init(id: ChatSpeechPreparation.defaultModelID, isInstalled: false))
                didDownload = true
            },
            prepareServer: { _ in }
        )
        let speech = ChatResponseSpeech(synthesize: { _, settings in
            XCTAssertTrue(didDownload)
            XCTAssertEqual(settings.textToSpeechModelID, ChatSpeechPreparation.defaultModelID)
            return Data([1])
        }, makePlayback: { _ in playback })

        await playResponse(speech, playback: playback, id: UUID(), settings: settings, preparation: preparation)

        XCTAssertTrue(didDownload)
        XCTAssertNil(speech.errorMessage)
        speech.stop()
    }

    func testAutomaticModelResolutionRejectsCachePathThatIsAFile() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: cache)
        defer { try? FileManager.default.removeItem(at: cache) }

        do {
            _ = try await ChatSpeechPreparation.resolveModel(for: NativSettings(modelSearchPath: cache.path))
            XCTFail("Invalid cache paths must not be treated as an empty model library")
        } catch LocalModelDiscoveryError.notDirectory(let path) {
            XCTAssertEqual(path, cache.path)
        }
    }

    func testAutomaticModelSelectionPrefersInstalledChoiceAndOnlyFallsBackWithoutTTS() {
        func local(_ id: String, capabilities: Set<LocalModelCapability>) -> LocalModel {
            LocalModel(
                repoID: id, snapshotURL: nil, modifiedAt: nil, sizeBytes: nil,
                parameterCount: nil, quantizationBits: nil, quantizationGroupSize: nil,
                contextSize: nil, provider: nil, capabilities: capabilities, drafterKind: nil, hiddenSize: nil
            )
        }
        let first = local("a/voice", capabilities: [.textToSpeech])
        let preferred = local("z/voice", capabilities: [.textToSpeech])
        let language = local("a/chat", capabilities: [.text])
        XCTAssertEqual(
            ChatSpeechPreparation.selectModel(preferredModelID: preferred.repoID, installedModels: [first, preferred, language]),
            .init(id: preferred.repoID, isInstalled: true)
        )
        for preference in [nil, "removed/voice"] {
            XCTAssertEqual(
                ChatSpeechPreparation.selectModel(preferredModelID: preference, installedModels: [preferred, language, first]),
                .init(id: first.repoID, isInstalled: true)
            )
            XCTAssertEqual(
                ChatSpeechPreparation.selectModel(preferredModelID: preference, installedModels: [language]),
                .init(id: "nativ-community/phonon", isInstalled: false)
            )
        }
    }

    private func playResponse(
        _ speech: ChatResponseSpeech, playback: TestSpeechPlayback, id: UUID,
        text: String = "Response", settings: NativSettings? = nil,
        preparation: ChatSpeechPreparation? = nil
    ) async {
        let played = expectation(description: "Response played")
        playback.onPlay = { played.fulfill() }
        speech.stop()
        speech.toggle(messageID: id, text: text, settings: settings ?? self.settings, preparation: preparation)
        await fulfillment(of: [played], timeout: 2)
        XCTAssertEqual(speech.phase, .playing)
    }
}

@MainActor
private final class TestSpeechPlayback: ChatSpeechPlayback {
    var onFinish: ((String?) -> Void)?
    var onPlay: () -> Void
    private let canPlay: Bool
    private(set) var stopCount = 0

    init(onPlay: @escaping () -> Void = {}, canPlay: Bool = true) {
        self.onPlay = onPlay
        self.canPlay = canPlay
    }

    func play() -> Bool { onPlay(); return canPlay }
    func stop() { stopCount += 1 }
}
