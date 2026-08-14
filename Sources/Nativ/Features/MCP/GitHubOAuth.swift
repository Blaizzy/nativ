import Foundation
import Security

struct GitHubOAuthDeviceAuthorization: Equatable, Sendable {
    let userCode: String
    let verificationURL: URL
}

struct GitHubOAuthCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let accessTokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?

    func hasUsableAccessToken(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let accessTokenExpiresAt else {
            return true
        }
        return accessTokenExpiresAt.timeIntervalSince(date) > leeway
    }

    func hasUsableRefreshToken(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard refreshToken?.isEmpty == false else {
            return false
        }
        guard let refreshTokenExpiresAt else {
            return true
        }
        return refreshTokenExpiresAt.timeIntervalSince(date) > leeway
    }
}

protocol GitHubOAuthCredentialStoring: Sendable {
    func load() throws -> GitHubOAuthCredential?
    func save(_ credential: GitHubOAuthCredential) throws
    func delete() throws
}

struct KeychainGitHubOAuthCredentialStore: GitHubOAuthCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "dev.nativ.github-oauth",
        account: String = "github.com"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> GitHubOAuthCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.keychainError(status)
        }
        return try JSONDecoder().decode(GitHubOAuthCredential.self, from: data)
    }

    func save(_ credential: GitHubOAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw Self.keychainError(updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.keychainError(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.keychainError(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainError(_ status: OSStatus) -> Error {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil)
                    as String? ?? "Keychain error \(status)",
            ]
        )
    }
}

struct GitHubOAuthConfiguration: Equatable, Sendable {
    static let clientIDInfoDictionaryKey = "NativGitHubAppClientID"
    static let appSlugInfoDictionaryKey = "NativGitHubAppSlug"

    let clientID: String
    let appSlug: String

    var installationURL: URL {
        URL(string: "https://github.com/apps/\(appSlug)/installations/new")!
    }

    static func bundled(in bundle: Bundle = .main) -> Self? {
        guard let rawClientID = bundle.object(
            forInfoDictionaryKey: clientIDInfoDictionaryKey
        ) as? String,
        let rawAppSlug = bundle.object(
            forInfoDictionaryKey: appSlugInfoDictionaryKey
        ) as? String else {
            return nil
        }
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSlug = rawAppSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let validSlugCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-")
        )
        guard !clientID.isEmpty,
              !clientID.contains("$("),
              !appSlug.isEmpty,
              !appSlug.contains("$("),
              appSlug.unicodeScalars.allSatisfy(validSlugCharacters.contains)
        else {
            return nil
        }
        return Self(clientID: clientID, appSlug: appSlug)
    }
}

protocol GitHubOAuthTransporting: Sendable {
    func requestDeviceAuthorization(clientID: String) async throws
        -> GitHubOAuthDeviceCodeResponse
    func pollForToken(clientID: String, deviceCode: String) async throws
        -> GitHubOAuthTokenResponse
    func refreshToken(clientID: String, refreshToken: String) async throws
        -> GitHubOAuthTokenResponse
    func hasInstallation(accessToken: String, appSlug: String) async throws -> Bool
}

struct GitHubOAuthDeviceCodeResponse: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: TimeInterval
    let interval: TimeInterval
}

struct GitHubOAuthTokenResponse: Equatable, Sendable {
    let accessToken: String?
    let expiresIn: TimeInterval?
    let refreshToken: String?
    let refreshTokenExpiresIn: TimeInterval?
    let error: String?
    let errorDescription: String?

    func credential(at date: Date) throws -> GitHubOAuthCredential {
        guard let accessToken, !accessToken.isEmpty else {
            throw GitHubOAuthError.authorizationFailed(
                errorDescription ?? error ?? "GitHub returned no access token."
            )
        }
        return GitHubOAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: expiresIn.map { date.addingTimeInterval($0) },
            refreshTokenExpiresAt: refreshTokenExpiresIn.map {
                date.addingTimeInterval($0)
            }
        )
    }
}

struct GitHubOAuthURLSessionTransport: GitHubOAuthTransporting, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func requestDeviceAuthorization(
        clientID: String
    ) async throws -> GitHubOAuthDeviceCodeResponse {
        let response: DeviceCodePayload = try await post(
            to: URL(string: "https://github.com/login/device/code")!,
            form: ["client_id": clientID]
        )
        guard let verificationURL = URL(string: response.verificationURI),
              verificationURL.scheme == "https",
              verificationURL.host == "github.com"
        else {
            throw GitHubOAuthError.invalidAuthorizationURL
        }
        return GitHubOAuthDeviceCodeResponse(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: verificationURL,
            expiresIn: TimeInterval(response.expiresIn),
            interval: TimeInterval(response.interval ?? 5)
        )
    }

    func pollForToken(
        clientID: String,
        deviceCode: String
    ) async throws -> GitHubOAuthTokenResponse {
        let payload: TokenPayload = try await post(
            to: URL(string: "https://github.com/login/oauth/access_token")!,
            form: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
        )
        return payload.response
    }

    func refreshToken(
        clientID: String,
        refreshToken: String
    ) async throws -> GitHubOAuthTokenResponse {
        let payload: TokenPayload = try await post(
            to: URL(string: "https://github.com/login/oauth/access_token")!,
            form: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        return payload.response
    }

    func hasInstallation(
        accessToken: String,
        appSlug: String
    ) async throws -> Bool {
        var components = URLComponents(
            string: "https://api.github.com/user/installations"
        )!
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, urlResponse) = try await session.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(
                  InstallationsPayload.self,
                  from: data
              )
        else {
            throw GitHubOAuthError.invalidServerResponse
        }
        return payload.installations.contains {
            $0.appSlug.caseInsensitiveCompare(appSlug) == .orderedSame
        }
    }

    private func post<Response: Decodable>(
        to url: URL,
        form: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, urlResponse) = try await session.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw GitHubOAuthError.invalidServerResponse
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubOAuthError.invalidServerResponse
        }
    }

    private struct DeviceCodePayload: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int?

        private enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenPayload: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let refreshToken: String?
        let refreshTokenExpiresIn: Int?
        let error: String?
        let errorDescription: String?

        var response: GitHubOAuthTokenResponse {
            GitHubOAuthTokenResponse(
                accessToken: accessToken,
                expiresIn: expiresIn.map(TimeInterval.init),
                refreshToken: refreshToken,
                refreshTokenExpiresIn: refreshTokenExpiresIn.map(TimeInterval.init),
                error: error,
                errorDescription: errorDescription
            )
        }

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case error
            case errorDescription = "error_description"
        }
    }

    private struct InstallationsPayload: Decodable {
        struct Installation: Decodable {
            let appSlug: String

            private enum CodingKeys: String, CodingKey {
                case appSlug = "app_slug"
            }
        }

        let installations: [Installation]
    }
}

protocol GitHubOAuthAuthorizing: Sendable {
    func accessToken(
        onDeviceAuthorization: @escaping @Sendable (
            GitHubOAuthDeviceAuthorization
        ) async -> Void,
        onInstallationRequired: @escaping @Sendable (URL) async -> Void
    ) async throws -> String
}

actor GitHubOAuthManager: GitHubOAuthAuthorizing {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let configuration: GitHubOAuthConfiguration
    private let credentials: any GitHubOAuthCredentialStoring
    private let transport: any GitHubOAuthTransporting
    private let now: @Sendable () -> Date
    private let sleep: Sleeper
    private var authorizationTask: (id: UUID, task: Task<String, Error>)?

    init(
        configuration: GitHubOAuthConfiguration,
        credentials: any GitHubOAuthCredentialStoring = KeychainGitHubOAuthCredentialStore(),
        transport: any GitHubOAuthTransporting = GitHubOAuthURLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    static func configured() -> GitHubOAuthManager? {
        GitHubOAuthConfiguration.bundled().map {
            GitHubOAuthManager(configuration: $0)
        }
    }

    func accessToken(
        onDeviceAuthorization: @escaping @Sendable (
            GitHubOAuthDeviceAuthorization
        ) async -> Void,
        onInstallationRequired: @escaping @Sendable (URL) async -> Void
    ) async throws -> String {
        if let existing = authorizationTask {
            do {
                return try await value(of: existing.task)
            } catch is CancellationError where !Task.isCancelled {
                // A previous caller cancelled the shared authorization while
                // this caller is still active. Discard it and start again.
                if authorizationTask?.id == existing.id {
                    authorizationTask = nil
                }
            }
        }

        let id = UUID()
        let task = Task {
            try await resolveAccessToken(
                onDeviceAuthorization: onDeviceAuthorization,
                onInstallationRequired: onInstallationRequired
            )
        }
        authorizationTask = (id, task)
        defer {
            if authorizationTask?.id == id {
                authorizationTask = nil
            }
        }
        return try await value(of: task)
    }

    private func value(of task: Task<String, Error>) async throws -> String {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func resolveAccessToken(
        onDeviceAuthorization: @escaping @Sendable (
            GitHubOAuthDeviceAuthorization
        ) async -> Void,
        onInstallationRequired: @escaping @Sendable (URL) async -> Void
    ) async throws -> String {
        let accessToken: String
        if let stored = try credentials.load() {
            if stored.hasUsableAccessToken(at: now()) {
                accessToken = stored.accessToken
            } else if let refreshToken = stored.refreshToken,
                      stored.hasUsableRefreshToken(at: now()) {
                let response = try await transport.refreshToken(
                    clientID: configuration.clientID,
                    refreshToken: refreshToken
                )
                if response.error == nil {
                    let refreshed = try response.credential(at: now())
                    try credentials.save(refreshed)
                    accessToken = refreshed.accessToken
                } else {
                    // GitHub rejected the refresh token. Clear only this
                    // unusable credential and fall back to device flow. A
                    // transport failure above leaves Keychain untouched so a
                    // retry does not unnecessarily reopen the browser.
                    try credentials.delete()
                    accessToken = try await authorize(
                        onDeviceAuthorization: onDeviceAuthorization
                    )
                }
            } else {
                try credentials.delete()
                accessToken = try await authorize(
                    onDeviceAuthorization: onDeviceAuthorization
                )
            }
        } else {
            accessToken = try await authorize(
                onDeviceAuthorization: onDeviceAuthorization
            )
        }

        try await ensureInstallation(
            accessToken: accessToken,
            onInstallationRequired: onInstallationRequired
        )
        return accessToken
    }

    private func authorize(
        onDeviceAuthorization: @escaping @Sendable (
            GitHubOAuthDeviceAuthorization
        ) async -> Void
    ) async throws -> String {
        let device = try await transport.requestDeviceAuthorization(
            clientID: configuration.clientID
        )
        await onDeviceAuthorization(
            GitHubOAuthDeviceAuthorization(
                userCode: device.userCode,
                verificationURL: device.verificationURL
            )
        )

        let deadline = now().addingTimeInterval(device.expiresIn)
        var interval = max(device.interval, 1)
        while now() < deadline {
            try Task.checkCancellation()
            try await sleep(interval)
            let response = try await transport.pollForToken(
                clientID: configuration.clientID,
                deviceCode: device.deviceCode
            )
            if response.error == "authorization_pending" {
                continue
            }
            if response.error == "slow_down" {
                interval += 5
                continue
            }
            if let error = response.error {
                throw GitHubOAuthError.authorizationFailed(
                    response.errorDescription ?? error
                )
            }

            let credential = try response.credential(at: now())
            try credentials.save(credential)
            return credential.accessToken
        }
        throw GitHubOAuthError.authorizationTimedOut
    }

    private func ensureInstallation(
        accessToken: String,
        onInstallationRequired: @escaping @Sendable (URL) async -> Void
    ) async throws {
        if try await transport.hasInstallation(
            accessToken: accessToken,
            appSlug: configuration.appSlug
        ) {
            return
        }

        await onInstallationRequired(configuration.installationURL)
        let deadline = now().addingTimeInterval(600)
        while now() < deadline {
            try Task.checkCancellation()
            try await sleep(2)
            if try await transport.hasInstallation(
                accessToken: accessToken,
                appSlug: configuration.appSlug
            ) {
                return
            }
        }
        throw GitHubOAuthError.installationTimedOut
    }
}

enum GitHubOAuthError: LocalizedError, Equatable {
    case notConfigured
    case invalidAuthorizationURL
    case invalidServerResponse
    case authorizationTimedOut
    case installationTimedOut
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The Nativ GitHub App client ID is not configured."
        case .invalidAuthorizationURL:
            "GitHub returned an invalid authorization URL."
        case .invalidServerResponse:
            "GitHub returned an invalid OAuth response."
        case .authorizationTimedOut:
            "GitHub authorization timed out. Reconnect to try again."
        case .installationTimedOut:
            "GitHub App installation timed out. Reconnect to try again."
        case .authorizationFailed(let message):
            "GitHub authorization failed: \(message)"
        }
    }
}
