import Foundation
import NativServerKit
import Security

struct CustomHTTPTool: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var slug: String
    var summary: String
    var endpoint: String
    var parametersJSON: String
    var headerName: String?

    static let defaultParametersJSON = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "query": {
          "type": "string",
          "description": "The value to send to the service."
        }
      },
      "required": ["query"]
    }
    """#

    var toolName: String {
        "custom__\(slug)"
    }

    var displaySummary: String {
        summary.isEmpty ? "Sends model-provided JSON to \(endpoint)" : summary
    }

    func definition() throws -> MLXChatToolDefinition {
        let parameters = try MLXJSONValue(jsonData: Data(parametersJSON.utf8))
        guard case .object = parameters else {
            throw CustomHTTPToolError.invalidParameters
        }
        return MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: displaySummary,
            parameters: parameters
        ))
    }

    static func make(
        name: String,
        summary: String,
        endpoint: String,
        parametersJSON: String,
        headerName: String = "",
        id: UUID = UUID()
    ) throws -> Self {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slug = normalizedSlug(trimmedName) else {
            throw CustomHTTPToolError.invalidName
        }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw CustomHTTPToolError.invalidEndpoint
        }
        let normalizedHeaderName = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedHeaderName.isEmpty || isValidHeaderName(normalizedHeaderName) else {
            throw CustomHTTPToolError.invalidHeaderName
        }
        let tool = Self(
            id: id,
            name: trimmedName,
            slug: slug,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: url.absoluteString,
            parametersJSON: parametersJSON.trimmingCharacters(in: .whitespacesAndNewlines),
            headerName: normalizedHeaderName.isEmpty ? nil : normalizedHeaderName
        )
        _ = try tool.definition()
        return tool
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private static func normalizedSlug(_ name: String) -> String? {
        let lowered = name.lowercased()
        let characters = lowered.unicodeScalars.map { character -> Character in
            CharacterSet.alphanumerics.contains(character) ? Character(String(character)) : "_"
        }
        let slug = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !slug.isEmpty,
              slug.count <= 48,
              slug.unicodeScalars.first.map(CharacterSet.letters.contains) == true else {
            return nil
        }
        return slug
    }
}

enum CustomHTTPToolError: LocalizedError {
    case invalidName
    case invalidEndpoint
    case invalidParameters
    case invalidHeaderName
    case missingCredential
    case invalidResponse
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Use a short tool name that starts with a letter."
        case .invalidEndpoint:
            return "Enter a complete http or https URL."
        case .invalidParameters:
            return "Parameters must be a JSON object schema."
        case .invalidHeaderName:
            return "Header names can contain only letters, numbers, and hyphens."
        case .missingCredential:
            return "Enter a value for the configured request header."
        case .invalidResponse:
            return "The service returned an unreadable response."
        case let .httpStatus(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The service returned HTTP \(status)." : "The service returned HTTP \(status): \(detail)"
        }
    }
}

enum CustomHTTPToolCredentialPersistenceError: Error {
    case keychain(OSStatus)
    case invalidKeychainData
}

protocol CustomHTTPToolCredentialStoring {
    func load(for toolID: UUID) throws -> String?
    func save(_ value: String?, for toolID: UUID) throws
}

struct CustomHTTPToolKeychain: CustomHTTPToolCredentialStoring {
    let service: String

    init(service: String = "dev.local.Nativ.custom-http-tool") {
        self.service = service
    }

    func load(for toolID: UUID) throws -> String? {
        var query = baseQuery(for: toolID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CustomHTTPToolCredentialPersistenceError.keychain(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CustomHTTPToolCredentialPersistenceError.invalidKeychainData
        }
        return normalized(value)
    }

    func save(_ value: String?, for toolID: UUID) throws {
        guard let value = normalized(value) else {
            let status = SecItemDelete(baseQuery(for: toolID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CustomHTTPToolCredentialPersistenceError.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let query = baseQuery(for: toolID)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CustomHTTPToolCredentialPersistenceError.keychain(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CustomHTTPToolCredentialPersistenceError.keychain(addStatus)
        }
    }

    private func baseQuery(for toolID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: toolID.uuidString,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum CustomHTTPToolExecutor {
    static func execute(
        _ tool: CustomHTTPTool,
        argumentsJSON: String?,
        headerValue: String? = nil,
        credentialStore: CustomHTTPToolCredentialStoring = CustomHTTPToolKeychain(),
        session: URLSession = .shared
    ) async throws -> String {
        guard let endpoint = URL(string: tool.endpoint) else {
            throw CustomHTTPToolError.invalidEndpoint
        }
        let body = Data((argumentsJSON ?? "{}").utf8)
        _ = try JSONSerialization.jsonObject(with: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        if let headerName = tool.headerName {
            let value: String?
            if let headerValue {
                value = headerValue
            } else {
                value = try credentialStore.load(for: tool.id)
            }
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw CustomHTTPToolError.missingCredential
            }
            request.setValue(value, forHTTPHeaderField: headerName)
        }

        let (data, response) = try await session.data(for: request)
        let text = String(decoding: data.prefix(128_000), as: UTF8.self)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomHTTPToolError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw CustomHTTPToolError.httpStatus(httpResponse.statusCode, text)
        }
        return text.isEmpty ? "{}" : text
    }
}
