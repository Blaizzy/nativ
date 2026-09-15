import Foundation

public enum TraceJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([TraceJSON])
    case object([String: TraceJSON])
}

extension TraceJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TraceJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: TraceJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension TraceJSON {
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func canonicalString() throws -> String {
        String(decoding: try canonicalData(), as: UTF8.self)
    }

    public static func decode(_ data: Data) throws -> TraceJSON {
        try JSONDecoder().decode(TraceJSON.self, from: data)
    }

    public static func decode(_ string: String) throws -> TraceJSON {
        try decode(Data(string.utf8))
    }

    public init<Value: Encodable>(encoding value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try TraceJSON.decode(data)
    }
}

