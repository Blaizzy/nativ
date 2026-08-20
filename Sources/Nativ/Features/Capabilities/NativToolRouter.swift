import Foundation
import NativServerKit

actor NativToolRouter {
    private let providers: [any NativCapabilityProvider]
    private var reportedCollisions = false

    init(providers: [any NativCapabilityProvider]) {
        self.providers = providers
    }

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        var definitions: [MLXChatToolDefinition] = []
        for provider in providers.sorted(by: { $0.catalogRank < $1.catalogRank }) {
            definitions += await provider.definitions(options)
        }
        reportCollisions(in: definitions)

        let webSearchIsConfigured = ChatWebSearchToolRegistry.isConfigured()
        let webReadIsConfigured = ChatWebReadToolRegistry.isConfigured()
        definitions.removeAll { definition in
            let name = definition.function.name
            return !options.isToolEnabled(name)
                || (name == ChatWebSearchToolRegistry.toolName && !webSearchIsConfigured)
                || (name == ChatWebReadToolRegistry.toolName && !webReadIsConfigured)
        }
        return definitions
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        for provider in providers where await provider.handles(name) {
            return try await provider.call(name, argumentsJSON: argumentsJSON, context: context)
        }
        throw ChatImageToolError.unsupportedTool(name)
    }

    static func duplicateToolNames(in definitions: [MLXChatToolDefinition]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for definition in definitions {
            if !seen.insert(definition.function.name).inserted {
                duplicates.insert(definition.function.name)
            }
        }
        return duplicates.sorted()
    }

    private func reportCollisions(in definitions: [MLXChatToolDefinition]) {
        guard !reportedCollisions else {
            return
        }
        let duplicates = Self.duplicateToolNames(in: definitions)
        guard !duplicates.isEmpty else {
            return
        }
        reportedCollisions = true
        NSLog(
            "Nativ tool names are defined by more than one provider: %@",
            duplicates.joined(separator: ", ")
        )
    }
}
