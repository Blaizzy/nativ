import Foundation
import NativServerKit

enum ChatModelLibraryToolRegistry {
    static let toolName = "list_models"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "List all MLX models already downloaded on this Mac, including display name, exact repository ID, size, quantization, and capabilities.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:])
            ])
        ))]
    }
}

struct ChatModelLibraryToolResultPayload: Encodable {
    struct Model: Encodable {
        let displayName: String
        let repoID: String
        let sizeGB: Double?
        let parameterCount: Int64?
        let quantizationBits: Int?
        let capabilities: [String]

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case repoID = "repo_id"
            case sizeGB = "size_gb"
            case parameterCount = "parameter_count"
            case quantizationBits = "quantization_bits"
            case capabilities
        }
    }

    let ok: Bool
    let models: [Model]?
    let error: String?
}

struct ChatModelLibraryToolExecutor {
    func execute(call: MLXChatToolCall, context: ChatToolExecutionContext) async throws -> String {
        guard call.function?.name == ChatModelLibraryToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }

        let models: [LocalModel]
        do {
            models = try await LocalModelDiscovery.scan(
                path: context.modelSearchPath,
                additionalPaths: context.additionalModelSearchPaths
            )
        } catch LocalModelDiscoveryError.pathNotFound {
            models = []
        }
        let payload = ChatModelLibraryToolResultPayload(
            ok: true,
            models: models.map { model in
                ChatModelLibraryToolResultPayload.Model(
                    displayName: model.repoID.split(separator: "/").last.map(String.init)
                        ?? model.displayName,
                    repoID: model.repoID,
                    sizeGB: model.sizeBytes.map(gigabytes),
                    parameterCount: model.parameterCount,
                    quantizationBits: model.quantizationBits,
                    capabilities: model.capabilities.map(\.rawValue).sorted()
                )
            },
            error: nil
        )
        return try encodedPayload(payload)
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatModelLibraryToolResultPayload(ok: false, models: nil, error: error.localizedDescription)
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"Model library tool failed."}"#
    }

    private func gigabytes(_ bytes: Int64) -> Double {
        (Double(bytes) / 1_073_741_824 * 100).rounded() / 100
    }

    private func encodedPayload(_ payload: ChatModelLibraryToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
