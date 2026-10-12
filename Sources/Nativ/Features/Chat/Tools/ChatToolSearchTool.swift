import Foundation
import NativServerKit

struct ChatToolCapability: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case native
        case custom(String)
        case mcp(serverID: UUID, name: String)

        var kind: String {
            switch self {
            case .native: "native"
            case .custom: "custom"
            case .mcp: "mcp"
            }
        }

        var name: String? {
            switch self {
            case .native: nil
            case .custom(let name), .mcp(_, let name): name
            }
        }
    }

    let definition: MLXChatToolDefinition
    let source: Source
}

extension NativSettings {
    func exposure(for capability: ChatToolCapability) -> ToolExposureMode {
        let name = capability.definition.function.name
        if ChatToolRegistry.alwaysOnToolNames.contains(name) {
            return .on
        }
        if case .mcp(let serverID, _) = capability.source {
            return toolExposureMode(for: name, mcpServerID: serverID)
        }
        return toolExposureMode(for: name)
    }

    /// Tool Search only has something to find when an available tool is Discoverable.
    func toolSearchIsNeeded(among available: [ChatToolCapability]) -> Bool {
        available.contains {
            $0.definition.function.name != ChatToolSearchToolRegistry.toolName && exposure(for: $0) == .automatic
        }
    }

    func sendsDirectly(_ capability: ChatToolCapability, among available: [ChatToolCapability]) -> Bool {
        guard exposure(for: capability) == .on else { return false }
        return capability.definition.function.name != ChatToolSearchToolRegistry.toolName
            || toolSearchIsNeeded(among: available)
    }
}

enum ChatToolSearchToolRegistry {
    static let toolName = "tool_search"

    static let definition = MLXChatToolDefinition(
        function: MLXChatFunctionDefinition(
            name: toolName,
            description: #"Find and run tools that are not in your tool list. Search: {"action":"search","query":"weather"}. Run: {"action":"invoke","name":"EXACT_NAME","arguments":{...}} using a name and arguments_schema from the search results. Never call a found tool directly."#,
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("search"), .string("invoke")]),
                    ]),
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Words describing the capability needed."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Exact tool name returned by search."),
                    ]),
                    "arguments": .object([
                        "type": .string("object"),
                        "description": .string("Arguments matching the discovered tool schema."),
                    ]),
                ]),
                "required": .array([.string("action")]),
            ])
        ))
}

enum ChatToolSearchRequest: Equatable, Sendable {
    case search(String)
    case invoke(name: String, argumentsJSON: String)

    init(call: MLXChatToolCall) throws {
        guard call.function?.name == ChatToolSearchToolRegistry.toolName,
            let data = call.function?.arguments?.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = object["action"] as? String
        else {
            throw ChatToolSearchError.invalidArguments
        }

        switch action {
        case "search":
            guard let query = object["query"] as? String,
                !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ChatToolSearchError.invalidArguments
            }
            self = .search(query)
        case "invoke":
            guard let name = object["name"] as? String,
                !name.isEmpty,
                name != ChatToolSearchToolRegistry.toolName
            else {
                throw ChatToolSearchError.invalidArguments
            }
            let arguments = object["arguments"] ?? [:]
            guard JSONSerialization.isValidJSONObject(arguments) else {
                throw ChatToolSearchError.invalidArguments
            }
            let encoded = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            self = .invoke(name: name, argumentsJSON: String(decoding: encoded, as: UTF8.self))
        default:
            throw ChatToolSearchError.invalidArguments
        }
    }
}

enum ChatToolSearchError: LocalizedError {
    case invalidArguments
    case unavailableTool(String)
    case directInvocationRequired(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            #"tool_search arguments are invalid. Search with {"action":"search","query":"weather"}, then run a result with {"action":"invoke","name":"EXACT_NAME","arguments":{...}}."#
        case .unavailableTool(let name):
            #"No enabled tool is named \#(name). Search first with {"action":"search","query":"..."} and use an exact name from the results."#
        case .directInvocationRequired(let name):
            #"\#(name) must be run through tool_search: {"action":"invoke","name":"\#(name)","arguments":{...}}. Search for it first if you need its arguments_schema."#
        case .unknownTool(let name):
            "There is no tool named \(name). Use only tools from your tool list."
        }
    }
}

enum ChatToolSearchToolExecutor {
    enum Resolution {
        case searchResult(String)
        case invocation(MLXChatToolCall)
    }

    private struct SearchResult: Encodable {
        let instruction: String
        let matches: [Match]
    }

    private struct Match: Encodable {
        let name: String
        let description: String
        let argumentsSchema: MLXJSONValue
        let source: String
        let provider: String?

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case argumentsSchema = "arguments_schema"
            case source
            case provider
        }
    }

    static func search(
        query: String,
        capabilities: [ChatToolCapability]
    ) throws -> String {
        let normalizedQuery = normalized(query)
        let terms = normalizedQuery.split(separator: " ")
        let matches = capabilities.compactMap { capability -> (Int, ChatToolCapability)? in
            let definition = capability.definition
            let name = normalized(definition.function.name)
            let description = normalized(
                "\(definition.function.description) \(capability.source.name ?? "") \(capability.source.kind)"
            )
            var score = name == normalizedQuery ? 100 : 0
            if name.contains(normalizedQuery) { score += 40 }
            score += terms.reduce(into: 0) { total, term in
                if name.contains(term) {
                    total += 10
                } else if description.contains(term) {
                    total += 2
                }
            }
            return score > 0 ? (score, capability) : nil
        }.sorted {
            $0.0 == $1.0
                ? $0.1.definition.function.name < $1.1.definition.function.name
                : $0.0 > $1.0
        }.prefix(5).map { _, capability in
            let definition = capability.definition
            return Match(
                name: definition.function.name,
                description: definition.function.description,
                argumentsSchema: definition.function.parameters,
                source: capability.source.kind,
                provider: capability.source.name
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = SearchResult(
            instruction: matches.isEmpty
                ? "No tools matched. Try different words, or continue without a tool."
                : "Run a match with tool_search action=invoke, its exact name, and arguments matching arguments_schema. Do not call it directly.",
            matches: matches
        )
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func resolve(
        call: MLXChatToolCall,
        capabilities: [ChatToolCapability]
    ) throws -> Resolution {
        switch try ChatToolSearchRequest(call: call) {
        case .search(let query):
            return .searchResult(try search(query: query, capabilities: capabilities))
        case .invoke(let name, let argumentsJSON):
            guard capabilities.contains(where: { $0.definition.function.name == name }) else {
                throw ChatToolSearchError.unavailableTool(name)
            }
            return .invocation(
                MLXChatToolCall(id: nil, function: MLXChatFunctionCall(name: name, arguments: argumentsJSON))
            )
        }
    }
}
