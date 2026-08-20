import Foundation
import NativServerKit

enum NativToolError: LocalizedError {
    case missingArgument(String)
    case serverNotRunning
    case fileNotFound(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "This call needs a \(name)."
        case .serverNotRunning:
            "Start Nativ's local model server first."
        case .fileNotFound(let path):
            "There is no file at \(path)."
        case .timedOut(let what):
            "\(what) did not finish in time."
        }
    }
}

struct NativToolArguments: Sendable {
    private let values: [String: MLXJSONValue]

    init(json: String?) {
        guard let data = json?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MLXJSONValue.self, from: data),
              case .object(let object) = decoded
        else {
            values = [:]
            return
        }
        values = object
    }

    func string(_ name: String) -> String? {
        guard case .string(let value) = values[name], !value.isEmpty else {
            return nil
        }
        return value
    }

    func integer(_ name: String) -> Int? {
        guard case .number(let value) = values[name] else {
            return nil
        }
        return Int(value)
    }

    func required(_ name: String) throws -> String {
        guard let value = string(name) else {
            throw NativToolError.missingArgument(name)
        }
        return value
    }
}

struct NativTool: Sendable {
    let name: String
    let description: String
    let parameters: MLXJSONValue
    let run: @Sendable (NativToolArguments) async throws -> [String: MLXJSONValue]

    var definition: MLXChatToolDefinition {
        MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: name,
            description: description,
            parameters: parameters
        ))
    }

    static func schema(
        properties: [String: MLXJSONValue] = [:],
        required: [String] = []
    ) -> MLXJSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    static func text(_ description: String) -> MLXJSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func number(_ description: String) -> MLXJSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
