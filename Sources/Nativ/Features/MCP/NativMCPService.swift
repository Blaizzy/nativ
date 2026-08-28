import Foundation
import MCP
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
    private var model: NativModel?
    private var listeners: [NativMCPListener] = []
    private var announcedAgents: Set<UUID> = []

    init(preferences: NativMCPPreferences) {
        self.preferences = preferences
    }

    func restart(model: NativModel) async {
        self.model = model
        await stop()
        guard preferences.isEnabled else {
            model.setAgentAccessState(.off)
            return
        }
        let access = preferences.access
        guard !access.keys.isEmpty else {
            let message = "Nativ could not read its keys from the keychain, so no app can connect."
            model.setAgentAccessState(.failed(message))
            model.appendAgentAccessLog(message)
            return
        }
        let funnel = await NativFunnelIntegration(port: preferences.port).status()
        let host = funnel.isServing ? funnel.publicHost ?? "" : ""
        let endpoints = Dictionary(
            uniqueKeysWithValues: Set(access.keys.map(\.agent.scope)).map { scope in
                (
                    scope,
                    NativMCPEndpoint(
                        surface: surface(for: scope, access: access),
                        publicHosts: host.isEmpty ? [] : [host]
                    )
                )
            }
        )
        let listener = NativMCPListener(port: preferences.port) { [weak self] request in
            await self?.reply(to: request, access: access, endpoints: endpoints)
                ?? .error(statusCode: 503, MCPError.internalError("Nativ is not serving tools."))
        }
        do {
            try await listener.start()
            listeners = [listener]
            model.setAgentAccessState(.serving(port: preferences.port))
            model.appendAgentAccessLog(
                "Listening on port \(preferences.port) for \(access.keys.count) app(s)."
            )
        } catch {
            let message = "Could not listen on port \(preferences.port). \(error.localizedDescription)"
            model.setAgentAccessState(.failed(message))
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
        model?.setAgentAccessState(.off)
        model?.appendAgentAccessLog("Stopped.")
    }

    private func reply(
        to request: HTTPRequest,
        access: NativMCPAccess,
        endpoints: [NativMCPScope: NativMCPEndpoint]
    ) async -> HTTPResponse {
        let token = NativMCPRequestReader.bearerToken(in: request)
        guard let key = access.key(forSecret: token), let endpoint = endpoints[key.agent.scope] else {
            await report(nil, status: 401)
            return .error(statusCode: 401, MCPError.invalidRequest("Unknown key."))
        }
        let response = await endpoint.respond(to: request)
        await report(key.agent, status: response.statusCode)
        return response
    }

    private func report(_ agent: NativMCPAgent?, status: Int) async {
        guard let agent else {
            model?.appendAgentAccessLog("Refused a caller with an unknown key.")
            return
        }
        model?.appendAgentAccessLog("\(agent.name) (\(agent.scope.title)) → \(status).")
        guard announcedAgents.insert(agent.id).inserted else {
            return
        }
        _ = await NativNotificationService.shared.deliver(
            NativNotification(
                title: "App connected",
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
        let registry = router(for: settings, model: model)
        let definitions = await registry.definitions(
            NativToolCatalogOptions(
                canEditImage: false,
                disabledToolNames: Set(settings.disabledToolNames),
                webSearchIsConfigured: ChatWebSearchToolRegistry.isConfigured(),
                webReadIsConfigured: ChatWebReadToolRegistry.isConfigured()
            )
        )
        var usable: [MLXChatToolDefinition] = []
        for definition in definitions where access.permits(definition.function.name, in: scope) {
            let name = definition.function.name
            guard await registry.canRun(name), await registry.requiresConsent(name) == false else {
                continue
            }
            usable.append(definition)
        }
        return usable
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
        let result = try await router(for: settings, model: model).call(
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

    private func router(for settings: NativSettings, model: NativModel) -> NativToolRouter {
        NativToolRouter(
            providers: [
                NativActionToolProvider(model: model),
                CustomToolProvider(tools: settings.customTools),
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
