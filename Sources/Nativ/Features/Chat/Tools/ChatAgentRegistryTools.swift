import Foundation
import NativServerKit

enum ChatListAgentsToolRegistry {
    static let toolName = "list_agents"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "List every spawned sub-agent tracked this session, with its status.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:])
            ])
        ))]
    }
}

struct ChatListAgentsToolResultPayload: Encodable {
    struct Agent: Encodable {
        let agentID: String
        let task: String
        let status: String
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case agentID = "agent_id"
            case task
            case status
            case stopReason = "stop_reason"
        }
    }

    let ok: Bool
    let agents: [Agent]
    let error: String?
}

struct ChatListAgentsToolExecutor {
    @MainActor
    func execute(registry: ChatAgentRegistry?) -> String {
        let agents = (registry?.allRecords() ?? []).map {
            ChatListAgentsToolResultPayload.Agent(
                agentID: $0.id,
                task: $0.task,
                status: $0.status.rawValue,
                stopReason: $0.stopReason?.rawValue
            )
        }
        return (try? encodedPayload(ChatListAgentsToolResultPayload(ok: true, agents: agents, error: nil)))
            ?? #"{"ok":true,"agents":[]}"#
    }

    func failurePayload(error: Error) -> String {
        let payload = ChatListAgentsToolResultPayload(ok: false, agents: [], error: error.localizedDescription)
        return (try? encodedPayload(payload)) ?? #"{"ok":false,"error":"list_agents failed."}"#
    }

    private func encodedPayload(_ payload: ChatListAgentsToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

enum ChatCheckAgentToolRegistry {
    static let toolName = "check_agent"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Check a sub-agent's status, and its result once done.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "agent_id": .object([
                        "type": .string("string"),
                        "description": .string("The agent_id from spawn_agent or list_agents.")
                    ]),
                    "wait": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, blocks until the agent finishes. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("agent_id")])
            ])
        ))]
    }
}

struct ChatCheckAgentToolArguments: Decodable {
    let agentID: String
    let wait: Bool

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case wait
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(String.self, forKey: .agentID)
        wait = try container.decodeIfPresent(Bool.self, forKey: .wait) ?? false
    }
}

struct ChatCheckAgentToolResultPayload: Encodable {
    let ok: Bool
    let agentID: String?
    let status: String?
    let stopReason: String?
    let answer: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case agentID = "agent_id"
        case status
        case stopReason = "stop_reason"
        case answer
        case error
    }
}

enum ChatCheckAgentToolError: LocalizedError {
    case invalidArguments
    case unknownAgent(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The check_agent arguments were not valid JSON."
        case .unknownAgent(let agentID):
            return "No spawned agent with id \(agentID) is tracked this session."
        }
    }
}

struct ChatCheckAgentToolExecutor {
    private static let pollInterval: UInt64 = 200_000_000

    @MainActor
    func execute(call: MLXChatToolCall, registry: ChatAgentRegistry?) async throws -> String {
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatCheckAgentToolArguments.self, from: argumentsData)
        else {
            throw ChatCheckAgentToolError.invalidArguments
        }
        guard let registry, var record = registry.record(for: arguments.agentID) else {
            throw ChatCheckAgentToolError.unknownAgent(arguments.agentID)
        }

        if arguments.wait {
            while record.status == .queued || record.status == .running {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: Self.pollInterval)
                guard let refreshed = registry.record(for: arguments.agentID) else {
                    break
                }
                record = refreshed
            }
        }

        return try encodedPayload(ChatCheckAgentToolResultPayload(
            ok: true,
            agentID: record.id,
            status: record.status.rawValue,
            stopReason: record.stopReason?.rawValue,
            answer: record.result,
            error: record.error
        ))
    }

    func failurePayload(error: Error) -> String {
        let payload = ChatCheckAgentToolResultPayload(
            ok: false,
            agentID: nil,
            status: nil,
            stopReason: nil,
            answer: nil,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload)) ?? #"{"ok":false,"error":"check_agent failed."}"#
    }

    private func encodedPayload(_ payload: ChatCheckAgentToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

enum ChatSteerAgentToolRegistry {
    static let toolName = "steer_agent"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Queue a message into a running sub-agent, delivered at its next turn.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "agent_id": .object([
                        "type": .string("string"),
                        "description": .string("The agent_id from spawn_agent or list_agents.")
                    ]),
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The message to deliver as the sub-agent's next turn.")
                    ])
                ]),
                "required": .array([.string("agent_id"), .string("message")])
            ])
        ))]
    }
}

struct ChatSteerAgentToolArguments: Decodable {
    let agentID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case message
    }
}

struct ChatSteerAgentToolResultPayload: Encodable {
    let ok: Bool
    let error: String?
}

enum ChatSteerAgentToolError: LocalizedError {
    case invalidArguments
    case emptyMessage
    case unknownOrFinishedAgent(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The steer_agent arguments were not valid JSON."
        case .emptyMessage:
            return "steer_agent requires a non-empty message."
        case .unknownOrFinishedAgent(let agentID):
            return "\(agentID) isn't a running or queued agent, so it can't be steered."
        }
    }
}

struct ChatSteerAgentToolExecutor {
    @MainActor
    func execute(call: MLXChatToolCall, registry: ChatAgentRegistry?) throws -> String {
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatSteerAgentToolArguments.self, from: argumentsData)
        else {
            throw ChatSteerAgentToolError.invalidArguments
        }
        guard !arguments.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatSteerAgentToolError.emptyMessage
        }
        guard let registry, registry.queueSteerMessage(arguments.message, for: arguments.agentID) else {
            throw ChatSteerAgentToolError.unknownOrFinishedAgent(arguments.agentID)
        }
        return try encodedPayload(ChatSteerAgentToolResultPayload(ok: true, error: nil))
    }

    func failurePayload(error: Error) -> String {
        let payload = ChatSteerAgentToolResultPayload(ok: false, error: error.localizedDescription)
        return (try? encodedPayload(payload)) ?? #"{"ok":false,"error":"steer_agent failed."}"#
    }

    private func encodedPayload(_ payload: ChatSteerAgentToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
