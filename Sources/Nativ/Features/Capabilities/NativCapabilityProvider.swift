import Foundation
import NativServerKit

struct NativToolCatalogOptions: Sendable {
    let canEditImage: Bool
    let isToolEnabled: @Sendable (String) -> Bool

    init(canEditImage: Bool, isToolEnabled: @escaping @Sendable (String) -> Bool) {
        self.canEditImage = canEditImage
        self.isToolEnabled = isToolEnabled
    }
}

protocol NativCapabilityProvider: Sendable {
    var namespace: String { get }
    var catalogRank: Int { get }

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition]
    func handles(_ name: String) async -> Bool
    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome
}

struct NativeToolProvider: NativCapabilityProvider {
    let namespace = "native"
    let catalogRank = 0

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        ChatToolRegistry.definitions(canEditImage: options.canEditImage)
    }

    func handles(_ name: String) async -> Bool {
        ChatToolDispatcher.handles(name)
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        try await ChatToolDispatcher.execute(
            call: MLXChatToolCall(
                id: nil,
                function: MLXChatFunctionCall(name: name, arguments: argumentsJSON)
            ),
            context: context
        )
    }
}

struct CustomToolProvider: NativCapabilityProvider {
    let namespace = "custom"
    let catalogRank = 1
    let tools: [CustomTool]

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        tools.compactMap { try? $0.definition() }
    }

    func handles(_ name: String) async -> Bool {
        tools.contains { $0.toolName == name }
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        guard let tool = tools.first(where: { $0.toolName == name }) else {
            throw ChatImageToolError.unsupportedTool(name)
        }
        let result = try await CustomToolExecutor.execute(tool, argumentsJSON: argumentsJSON)
        return ChatToolExecutionOutcome(content: result, attachments: [])
    }
}

struct HostedMCPToolProvider: NativCapabilityProvider {
    let namespace = "mcp"
    let catalogRank = 2
    let listDefinitions: @MainActor @Sendable () -> [MLXChatToolDefinition]
    let handlesTool: @MainActor @Sendable (String) -> Bool
    let invoke: @MainActor @Sendable (String, String?) async throws -> String

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        await listDefinitions()
    }

    func handles(_ name: String) async -> Bool {
        await handlesTool(name)
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let result = try await invoke(name, argumentsJSON)
        return ChatToolExecutionOutcome(content: result, attachments: [])
    }
}
