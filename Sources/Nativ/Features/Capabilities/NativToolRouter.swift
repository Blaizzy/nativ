import Foundation
import NativServerKit

struct NativToolCatalogOptions: Sendable {
    let canEditImage: Bool
    let disabledToolNames: Set<String>
    let webSearchIsConfigured: Bool
    let webReadIsConfigured: Bool
}

enum NativToolCallResult: Sendable {
    case completed(ChatToolExecutionOutcome)
    case declined
    case cancelled
}

struct NativToolRouter: Sendable {
    private let providers: [any NativCapabilityProvider]
    private let fallback: any NativCapabilityProvider

    init(providers: [any NativCapabilityProvider], fallback: any NativCapabilityProvider) {
        self.providers = providers
        self.fallback = fallback
    }

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        var definitions = await fallback.definitions(options)
        for provider in providers {
            definitions += await provider.definitions(options)
        }
        definitions.removeAll { isHidden($0.function.name, options) }
        return definitions
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext,
        requestID: UUID,
        asking asker: any NativInteraction
    ) async throws -> NativToolCallResult {
        let provider = await responsibleProvider(for: name)
        if await provider.requiresConsent(name) {
            switch await asker.requestConsent(for: name, requestID: requestID) {
            case .cancelled:
                return .cancelled
            case .declined:
                return .declined
            case .approved:
                break
            }
        }
        return .completed(
            try await provider.call(name, argumentsJSON: argumentsJSON, context: context)
        )
    }

    func canRun(_ name: String) async -> Bool {
        for provider in providers where await provider.handles(name) {
            return true
        }
        return await fallback.handles(name)
    }

    func requiresConsent(_ name: String) async -> Bool {
        await responsibleProvider(for: name).requiresConsent(name)
    }

    private func responsibleProvider(for name: String) async -> any NativCapabilityProvider {
        for provider in providers where await provider.handles(name) {
            return provider
        }
        return fallback
    }

    private func isHidden(_ name: String, _ options: NativToolCatalogOptions) -> Bool {
        if options.disabledToolNames.contains(name) {
            return true
        }
        if name == ChatWebSearchToolRegistry.toolName, !options.webSearchIsConfigured {
            return true
        }
        if name == ChatWebReadToolRegistry.toolName, !options.webReadIsConfigured {
            return true
        }
        return false
    }
}
