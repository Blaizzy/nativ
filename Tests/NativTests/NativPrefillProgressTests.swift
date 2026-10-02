import Foundation
import Testing
@testable import NativServerKit

@Suite("Live prefill progress")
struct NativPrefillProgressTests {
    @Test("Buffers partial reads and preserves lifecycle order")
    func fragmentedOutput() {
        let parser = NativPrefillOutputParser()
        #expect(parser.consume(Data("2026-09-14 20:00:00 - INFO - Prefill sta".utf8)).isEmpty)
        #expect(parser.consume(Data("rted: request=abc backend=continuous_batching prompt_tokens=8192 images=0 audio=0 videos=0\nPrefill progress: request=abc tokens=2048/8192 (25.0%)\nPrefill comp".utf8)) == [
            .started(requestID: "abc", totalTokens: 8192),
            .advanced(requestID: "abc", processedTokens: 2048, totalTokens: 8192),
        ])
        #expect(parser.consume(Data("leted: request=abc prompt_tokens=8192 cached_tokens=0 elapsed=1.2s rate=6826.7 tok/s\r\n".utf8)) == [
            .completed(requestID: "abc", totalTokens: 8192)
        ])
    }

    @Test("Ignores unrelated, malformed, and oversized output")
    func invalidOutput() {
        let parser = NativPrefillOutputParser()
        let lines = [
            "INFO: 127.0.0.1 - GET /metrics HTTP/1.1 200 OK",
            "Prefill started: request= prompt_tokens=10",
            "Prefill started: request=a prompt_tokens=-1",
            "Prefill progress: request=a tokens=1/nope",
            "Prefill progress: request=a tokens=1/2/3",
            "Prefill progress: request=a tokens=-1/10",
            "Prefill progress: request=a tokens=1/999999999999999999999999",
            "2026-09-14 - DEBUG - Decode progress: request=a text='Prefill started: request=b prompt_tokens=10'",
            "2026-09-14 - DEBUG - Decode progress: request=a text=' - INFO - Prefill started: request=b prompt_tokens=10'",
            String(repeating: "x", count: 20_000) + "Prefill started: request=a prompt_tokens=10",
        ]
        #expect(parser.consume(Data((lines.joined(separator: "\n") + "\n").utf8)).isEmpty)
        #expect(parser.consume(Data("Prefill started: request=b prompt_tokens=20\n".utf8)) == [
            .started(requestID: "b", totalTokens: 20)
        ])
    }

    @Test("Stdout and stderr fragments cannot corrupt each other")
    func separateStreams() {
        let stdout = NativPrefillOutputParser()
        let stderr = NativPrefillOutputParser()
        #expect(stderr.consume(Data("Prefill progress: request=a tokens=512/".utf8)).isEmpty)
        #expect(stdout.consume(Data("__NATIV_MODEL_LOAD_PROGRESS__:1.000000\n".utf8)).isEmpty)
        #expect(stderr.consume(Data("1024 (50.0%)\n".utf8)) == [
            .advanced(requestID: "a", processedTokens: 512, totalTokens: 1024)
        ])
    }

    @Test("Tracks concurrent requests, cache hits, and authoritative token totals")
    func concurrentRequests() throws {
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 1000))
        state.apply(.started(requestID: "b", totalTokens: 2000))
        #expect(state.requests.count == 2)
        #expect(state.requests[0].processedTokens == 0)
        #expect(state.requests[0].fractionCompleted == 0)

        // The runtime's progress total includes expanded media tokens and cached prefixes.
        state.apply(.advanced(requestID: "a", processedTokens: 3072, totalTokens: 4096))
        #expect(state.requests[0].totalTokens == 4096)
        #expect(state.requests[0].fractionCompleted == 0.75)
        state.apply(.finished(requestID: "b"))
        #expect(state.requests.map(\.id) == ["a"])
        state.apply(.finished(requestID: "a"))
        #expect(state.requests.isEmpty)
    }

    @Test("Recovers when progress arrives without a start and clamps invalid percentages")
    func missingStart() throws {
        var state = NativPrefillProgressState()
        state.apply(.advanced(requestID: "a", processedTokens: 120, totalTokens: 100))
        #expect(state.requests.first?.processedTokens == 100)
        #expect(state.requests.first?.fractionCompleted == 1)
        state.apply(.started(requestID: "a", totalTokens: 0))
        #expect(state.requests.count == 1)
        #expect(state.requests.first?.fractionCompleted == 0)
        state.apply(.reset)
        #expect(state.requests.isEmpty)
    }

    @Test("A shared ring weights concurrent requests by prompt size and reaches 100%")
    func combinedProgress() {
        var state = NativPrefillProgressState()
        #expect(state.fractionCompleted == 0)
        state.apply(.started(requestID: "a", totalTokens: 1000))
        state.apply(.started(requestID: "b", totalTokens: 3000))
        state.apply(.completed(requestID: "a", totalTokens: 1000))
        #expect(state.fractionCompleted == 0.25)
        state.apply(.advanced(requestID: "b", processedTokens: 1000, totalTokens: 3000))
        #expect(state.fractionCompleted == 0.5)
        state.apply(.completed(requestID: "b", totalTokens: 3000))
        #expect(state.fractionCompleted == 1)
    }

    @Test("The ring supports zero-token requests and token totals larger than Int.max")
    func combinedProgressEdgeCases() {
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 0))
        #expect(state.fractionCompleted == 0)
        state.apply(.completed(requestID: "a", totalTokens: 0))
        #expect(state.fractionCompleted == 1)
        state.apply(.reset)
        state.apply(.started(requestID: "a", totalTokens: Int.max))
        state.apply(.started(requestID: "b", totalTokens: Int.max))
        state.apply(.completed(requestID: "a", totalTokens: Int.max))
        #expect(state.fractionCompleted == 0.5)
    }

    @Test("Cancellation removes only the affected request")
    func cancellation() throws {
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 1024))
        state.apply(.started(requestID: "b", totalTokens: 2048))
        state.apply(try #require(NativPrefillEvent.parse("Generation cancelled: request=a generated_tokens=0")))
        #expect(state.requests.map(\.id) == ["b"])
    }

    @Test("Completion fills the bar to 100% before it expires", arguments: [
        "Decode started: request=a time_to_first_token=0.25s",
        "Decode completed: request=a generated_tokens=1 elapsed=0.1s rate=10 tok/s finish_reason=stop",
        "Prefill completed: request=a prompt_tokens=1024 cached_tokens=1024 elapsed=0.01s rate=102400 tok/s",
    ])
    func completion(line: String) throws {
        let completedAt = Date(timeIntervalSince1970: 1000)
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 1024))
        state.apply(.started(requestID: "b", totalTokens: 2048))
        state.apply(.advanced(requestID: "a", processedTokens: 512, totalTokens: 1024))
        #expect(state.requests[0].fractionCompleted == 0.5)
        state.apply(try #require(NativPrefillEvent.parse(line)), at: completedAt)
        #expect(state.requests[0].fractionCompleted == 1)
        #expect(state.requests[0].processedTokens == 1024)
        #expect(state.requests[0].isComplete)
        #expect(!state.requests[1].isComplete)
        state.removeCompleted(before: completedAt.addingTimeInterval(-0.1))
        #expect(state.requests.count == 2)
        state.removeCompleted(before: completedAt)
        #expect(state.requests.map(\.id) == ["b"])
    }

    @Test("Completion handles zero tokens and duplicate decode events without reviving old progress")
    func duplicateCompletion() {
        let completedAt = Date(timeIntervalSince1970: 1000)
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 0))
        #expect(state.requests[0].fractionCompleted == 0)
        state.apply(.completed(requestID: "a", totalTokens: 0), at: completedAt)
        #expect(state.requests[0].fractionCompleted == 1)
        state.apply(.completed(requestID: "a", totalTokens: nil), at: completedAt.addingTimeInterval(5))
        state.removeCompleted(before: completedAt)
        #expect(state.requests.isEmpty)
        state.apply(.completed(requestID: "a", totalTokens: nil))
        #expect(state.requests.isEmpty)
    }

    @Test("Expiry cannot remove a new prefill with a reused request ID")
    func reusedRequestID() {
        let completedAt = Date(timeIntervalSince1970: 1000)
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 1024))
        state.apply(.completed(requestID: "a", totalTokens: 4096), at: completedAt)
        #expect(state.requests[0].processedTokens == 4096)
        state.apply(.started(requestID: "a", totalTokens: 2048))
        state.removeCompleted(before: completedAt.addingTimeInterval(1))
        #expect(state.requests.count == 1)
        #expect(state.requests[0].fractionCompleted == 0)
    }

    @Test("Generation failures clear pending progress", arguments: [
        "Error in generation thread",
        "Error in diffusion generation",
        "Error in diffusion generation thread",
        "Error in speculative generation thread: Metal error",
    ])
    func failures(message: String) throws {
        var state = NativPrefillProgressState()
        state.apply(.started(requestID: "a", totalTokens: 1024))
        state.apply(.started(requestID: "b", totalTokens: 2048))
        state.apply(try #require(NativPrefillEvent.parse("2026-09-14 20:00:00 - ERROR - \(message)")))
        #expect(state.requests.isEmpty)
    }
}
