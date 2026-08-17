import Foundation

public enum NativRuntimeSettingsError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case unsupported

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid settings response"
        case .httpStatus(let statusCode, let body):
            return NativServerErrorMessage.endpointFailure(
                endpoint: "Settings endpoint",
                statusCode: statusCode,
                responseBody: body
            )
        case .unsupported:
            return "This server does not support live settings"
        }
    }

    public var errorDescription: String? {
        description
    }

    public var isUnsupported: Bool {
        switch self {
        case .unsupported:
            return true
        case .httpStatus(let statusCode, _):
            return statusCode == 404 || statusCode == 405
        case .invalidResponse:
            return false
        }
    }
}

public enum RuntimeSettingValue: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported settings value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var isNull: Bool {
        self == .null
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var displayText: String {
        switch self {
        case .bool(let value):
            return value ? "On" : "Off"
        case .int(let value):
            return "\(value)"
        case .double(let value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case .string(let value):
            return value
        case .null:
            return "Default"
        }
    }
}

public struct RuntimeSettingSpec: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let type: String
    public let defaultValue: RuntimeSettingValue
    public let reloadKinds: [String]
    public let allowed: [String]?
    public let help: String

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case defaultValue = "default"
        case reloadKinds = "reload_kinds"
        case allowed
        case help
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        defaultValue =
            try container.decodeIfPresent(RuntimeSettingValue.self, forKey: .defaultValue) ?? .null
        reloadKinds = try container.decodeIfPresent([String].self, forKey: .reloadKinds) ?? []
        allowed = try container.decodeIfPresent([String].self, forKey: .allowed)
        help = try container.decodeIfPresent(String.self, forKey: .help) ?? ""
    }

    public init(
        name: String,
        type: String,
        defaultValue: RuntimeSettingValue,
        reloadKinds: [String],
        allowed: [String]?,
        help: String
    ) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.reloadKinds = reloadKinds
        self.allowed = allowed
        self.help = help
    }

    public var allowsNull: Bool {
        type.hasSuffix("_or_none")
    }

    public var reloadsModels: Bool {
        !reloadKinds.isEmpty
    }
}

public struct RuntimeSettingsSnapshot: Decodable, Equatable, Sendable {
    public let schema: [RuntimeSettingSpec]
    public let current: [String: RuntimeSettingValue]
    public let fingerprint: String

    private enum CodingKeys: String, CodingKey {
        case schema, current, fingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent([RuntimeSettingSpec].self, forKey: .schema) ?? []
        current =
            try container.decodeIfPresent([String: RuntimeSettingValue].self, forKey: .current) ?? [:]
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
    }

    public init(
        schema: [RuntimeSettingSpec],
        current: [String: RuntimeSettingValue],
        fingerprint: String
    ) {
        self.schema = schema
        self.current = current
        self.fingerprint = fingerprint
    }
}

public struct RuntimeSettingRejection: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let reason: String

    public var id: String { name }
}

public struct RuntimeSettingsUpdate: Decodable, Equatable, Sendable {
    public let op: String
    public let applied: [String: RuntimeSettingValue]
    public let rejected: [RuntimeSettingRejection]
    public let reloadKinds: [String]
    public let fingerprint: String
    public let current: [String: RuntimeSettingValue]

    private enum CodingKeys: String, CodingKey {
        case op, applied, rejected, fingerprint, current
        case reloadKinds = "reload_kinds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decodeIfPresent(String.self, forKey: .op) ?? "merge"
        applied =
            try container.decodeIfPresent([String: RuntimeSettingValue].self, forKey: .applied) ?? [:]
        rejected =
            try container.decodeIfPresent([RuntimeSettingRejection].self, forKey: .rejected) ?? []
        reloadKinds = try container.decodeIfPresent([String].self, forKey: .reloadKinds) ?? []
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        current =
            try container.decodeIfPresent([String: RuntimeSettingValue].self, forKey: .current) ?? [:]
    }
}

public final class NativRuntimeSettingsClient {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        apiKey: String? = nil,
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func fetch() async throws -> RuntimeSettingsSnapshot {
        let data = try await send(makeRequest(method: "GET", body: nil))
        do {
            return try decoder.decode(RuntimeSettingsSnapshot.self, from: data)
        } catch {
            throw NativRuntimeSettingsError.invalidResponse
        }
    }

    public func update(
        _ values: [String: RuntimeSettingValue],
        resettingUnlistedToDefaults: Bool = false
    ) async throws -> RuntimeSettingsUpdate {
        let body: Data
        if resettingUnlistedToDefaults {
            body = try encoder.encode(ReplacePayload(op: "replace", values: values))
        } else {
            body = try encoder.encode(values)
        }
        let data = try await send(makeRequest(method: "PATCH", body: body))
        do {
            return try decoder.decode(RuntimeSettingsUpdate.self, from: data)
        } catch {
            throw NativRuntimeSettingsError.invalidResponse
        }
    }

    private struct ReplacePayload: Encodable {
        let op: String
        let values: [String: RuntimeSettingValue]
    }

    private func makeRequest(method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/settings"))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativRuntimeSettingsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                throw NativRuntimeSettingsError.unsupported
            }
            throw NativRuntimeSettingsError.httpStatus(
                httpResponse.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }
}
