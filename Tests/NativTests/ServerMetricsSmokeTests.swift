import XCTest
@testable import NativServerKit

final class ServerMetricsSmokeTests: XCTestCase {
    private static let defaultModel = "mlx-community/Qwen3.5-0.8B-8bit"
    private static let defaultPrompts = [
        "In one sentence, explain what MLX is useful for.",
        "Name three practical ways to reduce latency in a local model server.",
        "Write a tiny JSON object with keys status and note.",
    ]

    func testMetricsDeltaAcrossChatQueries() async throws {
        guard ProcessInfo.processInfo.environment["NATIV_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set NATIV_LIVE_SMOKE=1 with a running server to exercise this test.")
        }

        let environment = ProcessInfo.processInfo.environment
        let baseURL = URL(string: environment["NATIV_SMOKE_BASE_URL"] ?? "http://127.0.0.1:8080")!
        let model = environment["NATIV_SMOKE_MODEL"] ?? Self.defaultModel
        let maxTokens = Int(environment["NATIV_SMOKE_MAX_TOKENS"] ?? "") ?? 48

        let metricsClient = NativMetricsClient(baseURL: baseURL, timeout: 10)
        let chatClient = NativChatClient(baseURL: baseURL)

        let before = try await metricsClient.fetchMetrics()
        printMetrics("before", before)

        for (index, prompt) in Self.defaultPrompts.enumerated() {
            let request = MLXChatCompletionRequest(
                model: model,
                messages: [MLXChatMessage(role: "user", content: prompt)],
                maxTokens: maxTokens,
                temperature: 0,
                topK: 40,
                topP: 1.0,
                minP: 0.0
            )
            let started = Date()
            let response = try await chatClient.completeChat(request)
            let elapsed = Date().timeIntervalSince(started)
            print("== query \(index + 1)/\(Self.defaultPrompts.count) == (\(String(format: "%.2f", elapsed))s)")
            print(response.content.isEmpty ? "<empty>" : response.content)
        }

        let after = try await metricsClient.fetchMetrics()
        printMetrics("after", after)
        printDelta(before: before.summary, after: after.summary)
        XCTAssertGreaterThanOrEqual(after.summary.requestsCompleted, before.summary.requestsCompleted)
    }

    private func printMetrics(_ label: String, _ metrics: NativMetrics) {
        let summary = metrics.summary
        print("\n== \(label) metrics ==")
        print("requests completed: \(summary.requestsCompleted)")
        print("requests failed:    \(summary.requestsFailed)")
        print("prompt tokens:      \(summary.promptTokensTotal)")
        print("generated tokens:   \(summary.generatedTokensTotal)")
        print("processed tokens:   \(summary.totalProcessedTokens)")
        print("avg decode tok/s:   \(summary.averageDecodeTokensPerSecond)")
    }

    private func printDelta(before: NativMetricsSummary, after: NativMetricsSummary) {
        print("\n== delta ==")
        print("requests_completed: \(after.requestsCompleted - before.requestsCompleted)")
        print("requests_failed:    \(after.requestsFailed - before.requestsFailed)")
        print("prompt_tokens_total: \(after.promptTokensTotal - before.promptTokensTotal)")
        print("generated_tokens_total: \(after.generatedTokensTotal - before.generatedTokensTotal)")
        print("total_processed_tokens: \(after.totalProcessedTokens - before.totalProcessedTokens)")
    }
}
