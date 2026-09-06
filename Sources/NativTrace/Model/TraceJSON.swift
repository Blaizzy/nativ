import Foundation

/// A lossless, `Sendable` JSON value.
///
/// Trace payloads are stored as JSON rather than as Swift enums with associated
/// values so that a build of Nativ can read a trace written by a newer build:
/// fields it does not understand survive decode, re-encode, and export instead
/// of being dropped on the floor. Typed access happens through
/// `TracePayloadView` conformances, which read what they need and ignore the
/// rest.
///
/// Integers and floating-point numbers are separate cases so that a token count
/// written as `1204` does not come back as `1204.0`.
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
    /// Byte representation used for storage, hashing, and equality of payloads.
    ///
    /// Deterministic for a given value: object keys are sorted and slashes are
    /// left unescaped. Content addressing in `TraceStore` depends on this, so
    /// the encoder options must not be relaxed without a schema migration.
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

    /// Wraps an already-`Encodable` value, so producers can hand over their own
    /// structs without hand-building a `TraceJSON` tree.
    public init<Value: Encodable>(encoding value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try TraceJSON.decode(data)
    }
}

extension TraceJSON {
    public subscript(key: String) -> TraceJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public subscript(index: Int) -> TraceJSON? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): Int(exactly: value)
        case .double(let value): Int(exactly: value.rounded())
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [TraceJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: TraceJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension TraceJSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension TraceJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension TraceJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension TraceJSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension TraceJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TraceJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: TraceJSON...) { self = .array(elements) }
}

extension TraceJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, TraceJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
