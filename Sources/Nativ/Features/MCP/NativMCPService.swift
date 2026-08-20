import Foundation
import NativServerKit

enum NativMCPServiceError: LocalizedError {
    case notPermitted(String)
    case needsApproval(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted(let name):
            "\(name) is not available to this caller."
        case .needsApproval(let name):
            "\(name) needs approval inside Nativ before it can run from outside."
        }
    }
}

@MainActor
final class NativMCPService {
    private let preferences: NativMCPPreferences
    private let host: MCPHostManager
    private var model: NativModel?
    private var listeners: [NativMCPListener] = []
    private(set) var lastError: String?

    init(preferences: NativMCPPreferences, host: MCPHostManager) {
        self.preferences = preferences
        self.host = host
    }

    func restart(model: NativModel) async {
        self.model = model
        await stop()
        guard preferences.isEnabled else {
            return
        }
        let access = preferences.access
        await start(port: access.localPort, caller: .local, access: access, publicHosts: [])
        if let outsidePort = access.outsidePort {
            let host = preferences.publicHost.trimmingCharacters(in: .whitespaces)
            await start(
                port: outsidePort,
                caller: .outside,
                access: access,
                publicHosts: host.isEmpty ? [] : [host]
            )
        }
    }

    func stop() async {
        for listener in listeners {
            await listener.stop()
        }
        listeners = []
    }

    private func start(
        port: Int,
        caller: NativMCPCaller,
        access: NativMCPAccess,
        publicHosts: [String]
    ) async {
        let endpoint = NativMCPEndpoint(
            surface: surface(for: caller, access: access),
            publicHosts: publicHosts
        )
        do {
            try await endpoint.start()
            let listener = NativMCPListener(port: port, endpoint: endpoint, access: access)
            try await listener.start()
            listeners.append(listener)
        } catch {
            lastError = "Could not serve tools on port \(port): \(error.localizedDescription)"
        }
    }

    private func surface(
        for caller: NativMCPCaller,
        access: NativMCPAccess
    ) -> NativMCPToolSurface {
        NativMCPToolSurface(
            list: { [weak self] in
                guard let self else {
                    return []
                }
                return await self.definitions(for: caller, access: access)
            },
            call: { [weak self] name, argumentsJSON in
                guard let self else {
                    throw NativMCPServiceError.notPermitted(name)
                }
                return try await self.run(name, argumentsJSON: argumentsJSON, caller: caller, access: access)
            }
        )
    }

    private func definitions(
        for caller: NativMCPCaller,
        access: NativMCPAccess
    ) async -> [MLXChatToolDefinition] {
        guard let model else {
            return []
        }
        let settings = model.settings.normalized()
        let definitions = await router(for: settings).definitions(
            NativToolCatalogOptions(
                canEditImage: false,
                disabledToolNames: Set(settings.disabledToolNames),
                webSearchIsConfigured: ChatWebSearchToolRegistry.isConfigured(),
                webReadIsConfigured: ChatWebReadToolRegistry.isConfigured()
            )
        )
        return definitions.filter { access.permits($0.function.name, for: caller) }
    }

    private func run(
        _ name: String,
        argumentsJSON: String?,
        caller: NativMCPCaller,
        access: NativMCPAccess
    ) async throws -> String {
        guard access.permits(name, for: caller), let model else {
            throw NativMCPServiceError.notPermitted(name)
        }
        let settings = model.settings.normalized()
        let result = try await router(for: settings).call(
            name,
            argumentsJSON: argumentsJSON,
            context: context(for: settings, model: model),
            requestID: UUID(),
            asking: NativMCPDeclinedAsker()
        )
        switch result {
        case .completed(let outcome):
            return outcome.content
        case .declined, .cancelled:
            throw NativMCPServiceError.needsApproval(name)
        }
    }

    private func router(for settings: NativSettings) -> NativToolRouter {
        NativToolRouter(
            providers: [
                CustomToolProvider(tools: settings.customTools),
                HostedMCPToolProvider(host: host),
            ],
            fallback: NativeToolProvider()
        )
    }

    private func context(for settings: NativSettings, model: NativModel) -> ChatToolExecutionContext {
        ChatToolExecutionContext(
            imageGenerationModelID: settings.imageGenerationModelID,
            baseURL: settings.serverBaseURL,
            apiKey: settings.serverAPIKey,
            imageReferences: [],
            modelSearchPath: settings.expandedModelSearchPath,
            additionalModelSearchPaths: settings.additionalModelSearchPaths,
            huggingFaceToken: model.effectiveHuggingFaceToken,
            analyticsDatabaseURL: model.analyticsDatabaseURL
        )
    }
}

private struct NativMCPDeclinedAsker: NativInteraction {
    @MainActor
    func requestConsent(for toolName: String, requestID: UUID) async -> ChatToolConsentOutcome {
        .declined
    }
}
