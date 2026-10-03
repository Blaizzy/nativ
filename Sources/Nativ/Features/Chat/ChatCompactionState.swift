import CryptoKit
import Foundation
import NativServerKit

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

    static func threshold(modelContext: Int?, configuredContext: Int, maxOutput: Int) throws -> Int {
        let context = [modelContext, configuredContext].compactMap { $0 }.filter { $0 > 0 }.min() ?? 8192
        let threshold = min(context * 3 / 4, context - maxOutput - 1024)
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
