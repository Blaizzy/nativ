import XCTest

final class GitHubOAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReusesUsableKeychainCredentialWithoutStartingOAuth() async throws {
        let stored = GitHubOAuthCredential(
            accessToken: "ghu_stored",
            refreshToken: "ghr_stored",
            accessTokenExpiresAt: now.addingTimeInterval(3_600),
            refreshTokenExpiresAt: now.addingTimeInterval(86_400)
        )
        let credentials = InMemoryGitHubCredentialStore(stored)
        let transport = StubGitHubOAuthTransport()
        let manager = makeManager(credentials: credentials, transport: transport)

        let token = try await manager.accessToken(
            onDeviceAuthorization: { _ in
                XCTFail("A valid stored token must not start browser authorization")
            },
            onInstallationRequired: { _ in
                XCTFail("An installed app must not reopen GitHub")
            }
        )

        XCTAssertEqual(token, "ghu_stored")
        let counts = await transport.requestCounts()
        XCTAssertEqual(counts.device, 0)
        XCTAssertEqual(counts.poll, 0)
        XCTAssertEqual(counts.refresh, 0)
    }

    func testSilentlyRefreshesExpiredAccessTokenAndRotatesStoredTokens() async throws {
        let stored = GitHubOAuthCredential(
            accessToken: "ghu_expired",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: now.addingTimeInterval(-1),
            refreshTokenExpiresAt: now.addingTimeInterval(86_400)
        )
        let credentials = InMemoryGitHubCredentialStore(stored)
        let transport = StubGitHubOAuthTransport(
            refreshResponse: GitHubOAuthTokenResponse(
                accessToken: "ghu_refreshed",
                expiresIn: 28_800,
                refreshToken: "ghr_rotated",
                refreshTokenExpiresIn: 15_897_600,
                error: nil,
                errorDescription: nil
            )
        )
        let manager = makeManager(credentials: credentials, transport: transport)

        let token = try await manager.accessToken(
            onDeviceAuthorization: { _ in
                XCTFail("Refresh-token rotation must not open the browser")
            },
            onInstallationRequired: { _ in
                XCTFail("An installed app must not reopen GitHub")
            }
        )

        XCTAssertEqual(token, "ghu_refreshed")
        XCTAssertEqual(try credentials.load()?.accessToken, "ghu_refreshed")
        XCTAssertEqual(try credentials.load()?.refreshToken, "ghr_rotated")
        let counts = await transport.requestCounts()
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(counts.device, 0)
    }

    func testFirstAuthorizationPromptsOnceAndPersistsCredential() async throws {
        let credentials = InMemoryGitHubCredentialStore()
        let verificationURL = try XCTUnwrap(URL(string: "https://github.com/login/device"))
        let transport = StubGitHubOAuthTransport(
            deviceResponse: GitHubOAuthDeviceCodeResponse(
                deviceCode: "device-code",
                userCode: "ABCD-EFGH",
                verificationURL: verificationURL,
                expiresIn: 900,
                interval: 5
            ),
            pollResponses: [
                GitHubOAuthTokenResponse(
                    accessToken: nil,
                    expiresIn: nil,
                    refreshToken: nil,
                    refreshTokenExpiresIn: nil,
                    error: "authorization_pending",
                    errorDescription: nil
                ),
                GitHubOAuthTokenResponse(
                    accessToken: "ghu_authorized",
                    expiresIn: 28_800,
                    refreshToken: "ghr_authorized",
                    refreshTokenExpiresIn: 15_897_600,
                    error: nil,
                    errorDescription: nil
                ),
            ]
        )
        let recorder = DeviceAuthorizationRecorder()
        let manager = makeManager(credentials: credentials, transport: transport)

        let token = try await manager.accessToken(
            onDeviceAuthorization: { authorization in
                await recorder.record(authorization)
            },
            onInstallationRequired: { _ in
                XCTFail("An installed app must not open repository selection")
            }
        )

        XCTAssertEqual(token, "ghu_authorized")
        XCTAssertEqual(try credentials.load()?.accessToken, "ghu_authorized")
        let recordedAuthorizations = await recorder.values()
        XCTAssertEqual(
            recordedAuthorizations,
            [GitHubOAuthDeviceAuthorization(
                userCode: "ABCD-EFGH",
                verificationURL: verificationURL
            )]
        )
        let counts = await transport.requestCounts()
        XCTAssertEqual(counts.device, 1)
        XCTAssertEqual(counts.poll, 2)
    }

    func testTransientRefreshFailurePreservesCredentialAndDoesNotStartOAuth() async throws {
        let stored = GitHubOAuthCredential(
            accessToken: "ghu_expired",
            refreshToken: "ghr_keep",
            accessTokenExpiresAt: now.addingTimeInterval(-1),
            refreshTokenExpiresAt: now.addingTimeInterval(86_400)
        )
        let credentials = InMemoryGitHubCredentialStore(stored)
        let transport = StubGitHubOAuthTransport(refreshShouldFail: true)
        let manager = makeManager(credentials: credentials, transport: transport)

        do {
            _ = try await manager.accessToken(
                onDeviceAuthorization: { _ in
                    XCTFail("A temporary refresh failure must not open the browser")
                },
                onInstallationRequired: { _ in
                    XCTFail("A temporary refresh failure must not open GitHub")
                }
            )
            XCTFail("Expected the temporary transport failure")
        } catch {
            XCTAssertEqual(error as? GitHubOAuthError, .invalidServerResponse)
        }

        XCTAssertEqual(try credentials.load(), stored)
        let counts = await transport.requestCounts()
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(counts.device, 0)
    }

    func testMissingInstallationOpensRepositorySelectionAndWaitsForCompletion() async throws {
        let stored = GitHubOAuthCredential(
            accessToken: "ghu_stored",
            refreshToken: "ghr_stored",
            accessTokenExpiresAt: now.addingTimeInterval(3_600),
            refreshTokenExpiresAt: now.addingTimeInterval(86_400)
        )
        let credentials = InMemoryGitHubCredentialStore(stored)
        let transport = StubGitHubOAuthTransport(
            installationResponses: [false, true]
        )
        let recorder = InstallationURLRecorder()
        let manager = makeManager(credentials: credentials, transport: transport)

        let token = try await manager.accessToken(
            onDeviceAuthorization: { _ in
                XCTFail("A stored token must not restart device authorization")
            },
            onInstallationRequired: { url in
                await recorder.record(url)
            }
        )

        XCTAssertEqual(token, "ghu_stored")
        let recordedURLs = await recorder.values()
        XCTAssertEqual(
            recordedURLs,
            [URL(string: "https://github.com/apps/nativ/installations/new")!]
        )
        let counts = await transport.requestCounts()
        XCTAssertEqual(counts.installation, 2)
    }

    private func makeManager(
        credentials: InMemoryGitHubCredentialStore,
        transport: StubGitHubOAuthTransport
    ) -> GitHubOAuthManager {
        let fixedNow = now
        return GitHubOAuthManager(
            configuration: GitHubOAuthConfiguration(
                clientID: "Iv1.nativ",
                appSlug: "nativ"
            ),
            credentials: credentials,
            transport: transport,
            now: { fixedNow },
            sleep: { _ in }
        )
    }
}

private final class InMemoryGitHubCredentialStore: GitHubOAuthCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: GitHubOAuthCredential?

    init(_ credential: GitHubOAuthCredential? = nil) {
        self.credential = credential
    }

    func load() throws -> GitHubOAuthCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credential
    }

    func save(_ credential: GitHubOAuthCredential) throws {
        lock.lock()
        self.credential = credential
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        credential = nil
        lock.unlock()
    }
}

private actor StubGitHubOAuthTransport: GitHubOAuthTransporting {
    private let deviceResponse: GitHubOAuthDeviceCodeResponse
    private var pollResponses: [GitHubOAuthTokenResponse]
    private let refreshResponse: GitHubOAuthTokenResponse
    private let refreshShouldFail: Bool
    private var installationResponses: [Bool]
    private var deviceRequests = 0
    private var pollRequests = 0
    private var refreshRequests = 0
    private var installationRequests = 0

    init(
        deviceResponse: GitHubOAuthDeviceCodeResponse = GitHubOAuthDeviceCodeResponse(
            deviceCode: "unused",
            userCode: "UNUSED",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            interval: 5
        ),
        pollResponses: [GitHubOAuthTokenResponse] = [],
        refreshResponse: GitHubOAuthTokenResponse = GitHubOAuthTokenResponse(
            accessToken: nil,
            expiresIn: nil,
            refreshToken: nil,
            refreshTokenExpiresIn: nil,
            error: "unused",
            errorDescription: nil
        ),
        refreshShouldFail: Bool = false,
        installationResponses: [Bool] = [true]
    ) {
        self.deviceResponse = deviceResponse
        self.pollResponses = pollResponses
        self.refreshResponse = refreshResponse
        self.refreshShouldFail = refreshShouldFail
        self.installationResponses = installationResponses
    }

    func requestDeviceAuthorization(
        clientID: String
    ) async throws -> GitHubOAuthDeviceCodeResponse {
        deviceRequests += 1
        return deviceResponse
    }

    func pollForToken(
        clientID: String,
        deviceCode: String
    ) async throws -> GitHubOAuthTokenResponse {
        pollRequests += 1
        guard !pollResponses.isEmpty else {
            throw GitHubOAuthError.invalidServerResponse
        }
        return pollResponses.removeFirst()
    }

    func refreshToken(
        clientID: String,
        refreshToken: String
    ) async throws -> GitHubOAuthTokenResponse {
        refreshRequests += 1
        if refreshShouldFail {
            throw GitHubOAuthError.invalidServerResponse
        }
        return refreshResponse
    }

    func hasInstallation(
        accessToken: String,
        appSlug: String
    ) async throws -> Bool {
        installationRequests += 1
        guard let response = installationResponses.first else {
            throw GitHubOAuthError.invalidServerResponse
        }
        if installationResponses.count > 1 {
            installationResponses.removeFirst()
        }
        return response
    }

    func requestCounts() -> (
        device: Int,
        poll: Int,
        refresh: Int,
        installation: Int
    ) {
        (deviceRequests, pollRequests, refreshRequests, installationRequests)
    }
}

private actor InstallationURLRecorder {
    private var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }

    func values() -> [URL] {
        urls
    }
}

private actor DeviceAuthorizationRecorder {
    private var authorizations: [GitHubOAuthDeviceAuthorization] = []

    func record(_ authorization: GitHubOAuthDeviceAuthorization) {
        authorizations.append(authorization)
    }

    func values() -> [GitHubOAuthDeviceAuthorization] {
        authorizations
    }
}
