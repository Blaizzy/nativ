import Foundation
import MCP
import NativServerKit

struct NativMCPToolSurface: Sendable {
    let list: @Sendable () async -> [MLXChatToolDefinition]
    let call: @Sendable (String, String?) async throws -> String
}

struct NativMCPEndpoint: Sendable {
    private static let loopbackHosts = [
        "127.0.0.1:*",
        "localhost:*",
        "[::1]:*",
    ]

    let surface: NativMCPToolSurface
    let publicHosts: [String]

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        let server = Server(
            name: "nativ",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            capabilities: .init(tools: .init(listChanged: false))
        )
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

        let transport = StatelessHTTPServerTransport(validationPipeline: validationPipeline)
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, MCPError.internalError(error.localizedDescription))
        }
        let response = await transport.handleRequest(request)
        await server.stop()
        return response
    }

    private var validationPipeline: any HTTPRequestValidationPipeline {
        StandardValidationPipeline(validators: [
            OriginValidator(
                allowedHosts: Self.loopbackHosts + publicHosts,
                allowedOrigins: publicHosts.map { "https://\($0)" }
            ),
            NativMCPAcceptValidator(),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
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
