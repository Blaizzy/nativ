import Foundation

public struct NativRuntimeSettingsResponse: Decodable, Sendable {
    public let current: [String: MLXJSONValue]
    public let rejected: [Rejection]

    public struct Rejection: Decodable, Sendable {
        public let name: String
        public let reason: String
    }
}

public struct NativRuntimeSettingsClient: Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func update(_ values: [String: MLXJSONValue]) async throws -> NativRuntimeSettingsResponse {
        // Older bundled engines used spec_draft_* for the same settings.
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: await send(method: "GET"))
        var aliases: [String: String] = [:]
        for name in ["draft_model", "draft_kind"] where snapshot.current[name] == nil {
            if snapshot.current["spec_" + name] != nil {
                aliases[name] = "spec_" + name
            }
        }
        let payload = Dictionary(uniqueKeysWithValues: values.map { (aliases[$0.key] ?? $0.key, $0.value) })
        let data = try await send(method: "PATCH", body: JSONEncoder().encode(payload))
        let response = try JSONDecoder().decode(NativRuntimeSettingsResponse.self, from: data)
        var current = response.current
        for (name, alias) in aliases {
            current[name] = current.removeValue(forKey: alias)
        }
        return NativRuntimeSettingsResponse(current: current, rejected: response.rejected)
    }

    private struct Snapshot: Decodable {
        let current: [String: MLXJSONValue]
    }

    private func send(method: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/settings"))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SettingsError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw SettingsError.httpStatus(response.statusCode)
        }
        return data
    }

    private enum SettingsError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The server returned an invalid settings response."
            case .httpStatus(let status): "The server could not apply live settings (HTTP \(status))."
            }
        }
    }
}
