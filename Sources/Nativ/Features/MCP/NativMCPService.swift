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
    private var announcedAgents: Set<UUID> = []
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
        let host = preferences.publicHost.trimmingCharacters(in: .whitespaces)
        var endpoints: [NativMCPScope: NativMCPEndpoint] = [:]
        for scope in NativMCPScope.allCases {
            let endpoint = NativMCPEndpoint(
                surface: surface(for: scope, access: access),
                publicHosts: host.isEmpty ? [] : [host]
            )
            do {
                try await endpoint.start()
                endpoints[scope] = endpoint
            } catch {
                lastError = "Could not prepare agent access: \(error.localizedDescription)"
                return
            }
        }
        let listener = NativMCPListener(
            port: preferences.port,
            access: access,
            endpoints: endpoints,
            report: { [weak self] agent, status in
                await self?.report(agent, status: status)
            }
        )
        do {
            try await listener.start()
            listeners = [listener]
            model.appendAgentAccessLog("listening on port \(preferences.port)")
        } catch {
            let message = "could not listen on port \(preferences.port): \(error.localizedDescription)"
            lastError = message
            model.appendAgentAccessLog(message)
        }
    }

    func stop() async {
        guard !listeners.isEmpty else {
            return
        }
        for listener in listeners {
            await listener.stop()
        }
        listeners = []
        announcedAgents = []
        model?.appendAgentAccessLog("stopped")
    }

    private func report(_ agent: NativMCPAgent?, status: Int) async {
        guard let agent else {
            model?.appendAgentAccessLog("rejected a caller with an unknown key")
            return
        }
        model?.appendAgentAccessLog("\(agent.name) (\(agent.scope.title)) → \(status)")
        guard announcedAgents.insert(agent.id).inserted else {
            return
        }
        _ = await NativNotificationService.shared.deliver(
            NativNotification(
                title: "Agent connected",
                body: "\(agent.name) is using Nativ's tools."
            )
        )
    }

    private func surface(
        for scope: NativMCPScope,
        access: NativMCPAccess
    ) -> NativMCPToolSurface {
        NativMCPToolSurface(
            list: { [weak self] in
                guard let self else {
                    return []
                }
                return await self.definitions(for: scope, access: access)
            },
            call: { [weak self] name, argumentsJSON in
                guard let self else {
                    throw NativMCPServiceError.notPermitted(name)
                }
                return try await self.run(name, argumentsJSON: argumentsJSON, scope: scope, access: access)
            }
        )
    }

    private func definitions(
        for scope: NativMCPScope,
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
        return definitions.filter { access.permits($0.function.name, in: scope) }
    }

    private func run(
        _ name: String,
        argumentsJSON: String?,
        scope: NativMCPScope,
        access: NativMCPAccess
    ) async throws -> String {
        guard access.permits(name, in: scope), let model else {
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
