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
    private let formatVersion: Int?

    init(item: MLXJSONValue, request: MLXChatCompletionRequest, serverURL: URL) throws {
        self.model = request.model
        self.serverURL = serverURL
        let messages = NativResponsesClient.conversationMessages(request.messages)
        self.messageCount = messages.count
        self.prefixDigest = try Self.digest(messages)
        self.item = item
        self.formatVersion = 1
    }

    func input(for request: MLXChatCompletionRequest, serverURL: URL) throws -> [MLXJSONValue] {
        let messages = NativResponsesClient.conversationMessages(request.messages)
        // Older capsules may carry instructions, so rebuild them once from the transcript.
        guard formatVersion == 1, model == request.model, self.serverURL == serverURL,
              messageCount >= 0, messageCount <= messages.count,
              prefixDigest == (try Self.digest(Array(messages.prefix(messageCount)))) else {
            return try NativResponsesClient.inputItems(messages)
        }
        return [item] + (try NativResponsesClient.inputItems(Array(messages.dropFirst(messageCount))))
    }

    static func threshold(modelContext: Int?, configuredContext: Int, maxOutput: Int, percent: Int = 75) throws -> Int {
        let context = [modelContext, configuredContext].compactMap { $0 }.filter { $0 > 0 }.min() ?? 8192
        let percent = min(max(percent, 20), 90)
        let threshold = min(context * percent / 100, context - maxOutput - 1024)
        guard threshold > 0 else {
            throw NativChatError.serverError("Lower Max output to leave room for conversation compaction.")
        }
        return threshold
    }

    private static func digest(_ messages: [MLXChatMessage]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(messages)).map { String(format: "%02x", $0) }.joined()
    }
}
