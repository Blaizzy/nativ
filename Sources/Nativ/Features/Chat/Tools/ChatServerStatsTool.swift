import Foundation
import NativServerKit

enum ChatServerStatsToolRegistry {
    static let toolName = "get_server_stats"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Get this Mac's local model server performance stats: requests, tokens, speed, time to first token.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:])
            ])
        ))]
    }
}

struct ChatServerStatsToolResultPayload: Encodable {
    let ok: Bool
    let requestsCompleted: Int?
    let requestsFailed: Int?
    let promptTokensTotal: Int?
    let completionTokensTotal: Int?
    let generatedTokensTotal: Int?
    let avgDecodeTokensPerSecond: Double?
    let avgRequestTokensPerSecond: Double?
    let avgTimeToFirstTokenMs: Double?
    let peakMemoryGB: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case requestsCompleted = "requests_completed"
        case requestsFailed = "requests_failed"
        case promptTokensTotal = "prompt_tokens_total"
        case completionTokensTotal = "completion_tokens_total"
        case generatedTokensTotal = "generated_tokens_total"
        case avgDecodeTokensPerSecond = "avg_decode_tokens_per_second"
        case avgRequestTokensPerSecond = "avg_request_tokens_per_second"
        case avgTimeToFirstTokenMs = "avg_time_to_first_token_ms"
        case peakMemoryGB = "peak_memory_gb"
        case error
    }
}

struct ChatServerStatsToolExecutor {
    func execute(call: MLXChatToolCall, context: ChatToolExecutionContext) throws -> String {
        guard call.function?.name == ChatServerStatsToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }

        let store = NativAnalyticsStore(
            databaseURL: context.analyticsDatabaseURL ?? NativAnalyticsStore.defaultDatabaseURL()
        )
        let summary = store.fetchSummary()
        let payload = ChatServerStatsToolResultPayload(
            ok: true,
            requestsCompleted: summary.requestsCompleted,
            requestsFailed: summary.requestsFailed,
            promptTokensTotal: summary.promptTokensTotal,
            completionTokensTotal: summary.completionTokensTotal,
            generatedTokensTotal: summary.generatedTokensTotal,
            avgDecodeTokensPerSecond: rounded(summary.averageDecodeTokensPerSecond),
            avgRequestTokensPerSecond: rounded(summary.averageRequestTokensPerSecond),
            avgTimeToFirstTokenMs: rounded(summary.averageTTFTMilliseconds),
            peakMemoryGB: summary.peakMemoryBytesMax.map(gigabytes),
            error: nil
        )
        return try encodedPayload(payload)
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatServerStatsToolResultPayload(
            ok: false,
            requestsCompleted: nil,
            requestsFailed: nil,
            promptTokensTotal: nil,
            completionTokensTotal: nil,
            generatedTokensTotal: nil,
            avgDecodeTokensPerSecond: nil,
            avgRequestTokensPerSecond: nil,
            avgTimeToFirstTokenMs: nil,
            peakMemoryGB: nil,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Server stats tool failed."}"#
    }

    private func rounded(_ value: Double?) -> Double? {
        value.map { ($0 * 100).rounded() / 100 }
    }

    private func gigabytes(_ bytes: Int64) -> Double {
        (Double(bytes) / 1_073_741_824 * 100).rounded() / 100
    }

    private func encodedPayload(_ payload: ChatServerStatsToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
