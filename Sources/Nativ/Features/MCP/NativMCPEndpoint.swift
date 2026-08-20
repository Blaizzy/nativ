import Foundation
import MCP
import NativServerKit

struct NativMCPToolSurface: Sendable {
    let list: @Sendable () async -> [MLXChatToolDefinition]
    let call: @Sendable (String, String?) async throws -> String
}

actor NativMCPEndpoint {
    private let server: Server
    private let transport: StatelessHTTPServerTransport

    init(surface: NativMCPToolSurface, publicHosts: [String] = []) {
        server = Server(
            name: "nativ",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        transport = StatelessHTTPServerTransport(
            validationPipeline: publicHosts.isEmpty
                ? nil
                : StandardValidationPipeline(validators: [
                    OriginValidator(allowedHosts: publicHosts, allowedOrigins: []),
                    AcceptHeaderValidator(mode: .jsonOnly),
                    ContentTypeValidator(),
                    ProtocolVersionValidator(),
                ])
        )
        self.surface = surface
    }

    private let surface: NativMCPToolSurface

    func start() async throws {
        await server.withMethodHandler(ListTools.self) { [surface] _ in
            ListTools.Result(tools: await surface.list().map(Self.tool(from:)))
        }
        await server.withMethodHandler(CallTool.self) { [surface] parameters in
            do {
                let text = try await surface.call(
                    parameters.name,
                    Self.argumentsJSON(parameters.arguments)
                )
                return CallTool.Result(content: [.text(text)])
            } catch {
                return CallTool.Result(
                    content: [.text(error.localizedDescription)],
                    isError: true
                )
            }
        }
        try await server.start(transport: transport)
    }

    func stop() async {
        await server.stop()
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        await transport.handleRequest(request)
    }

    private static func tool(from definition: MLXChatToolDefinition) -> Tool {
        Tool(
            name: definition.function.name,
            description: definition.function.description,
            inputSchema: schema(from: definition.function.parameters)
        )
    }

    private static func schema(from parameters: MLXJSONValue) -> Value {
        guard let data = try? JSONEncoder().encode(parameters),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else {
            return .object([:])
        }
        return value
    }

    private static func argumentsJSON(_ arguments: [String: Value]?) -> String? {
        guard let arguments, !arguments.isEmpty,
              let data = try? JSONEncoder().encode(arguments)
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
