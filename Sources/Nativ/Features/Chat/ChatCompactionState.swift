import CryptoKit
import Foundation
import NativServerKit

struct ChatCompactionMetrics: Codable, Equatable {
    let inputTokensBefore: Int?
    let inputTokensAfter: Int?
}

struct ChatCompactionState: Codable, Equatable {
    let model: String
    let serverURL: URL
    let messageCount: Int
    let prefixDigest: String
    let item: MLXJSONValue

    init(item: MLXJSONValue, request: MLXChatCompletionRequest, serverURL: URL) throws {
        self.model = request.model
        self.serverURL = serverURL
        self.messageCount = request.messages.count
        self.prefixDigest = try Self.digest(request.messages)
        self.item = item
    }

    func input(for request: MLXChatCompletionRequest, serverURL: URL) throws -> [MLXJSONValue] {
        guard model == request.model, self.serverURL == serverURL,
              messageCount >= 0, messageCount <= request.messages.count,
              prefixDigest == (try Self.digest(Array(request.messages.prefix(messageCount)))) else {
            return try NativResponsesClient.inputItems(request.messages)
        }
        return [item] + (try NativResponsesClient.inputItems(Array(request.messages.dropFirst(messageCount))))
    }

    struct GenerationBudget: Equatable {
        let maxOutput: Int
        let threshold: Int
    }

    static func budget(modelContext: Int?, configuredContext: Int, maxOutput: Int, percent: Int = 75) throws -> GenerationBudget {
        let context = [modelContext, configuredContext].compactMap { $0 }.filter { $0 > 0 }.min() ?? 8192
        let percent = min(max(percent, 20), 90)
        guard context > 1 else {
            throw NativChatError.serverError("Increase Context window to leave room for conversation compaction.")
        }
        // Cap output at 75% of the effective context, keeping smaller user limits.
        // The server budgets summary generation separately; it does not share the
        // response's output reservation.
        let output = min(max(1, maxOutput), context * 3 / 4)
        return GenerationBudget(
            maxOutput: output,
            threshold: max(1, min(context * percent / 100, context - output))
        )
    }

    private static func digest(_ messages: [MLXChatMessage]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(messages)).map { String(format: "%02x", $0) }.joined()
    }
}
