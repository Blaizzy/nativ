import XCTest

final class HuggingFaceCacheTests: XCTestCase {
    private let customCache = "/Volumes/models/cache"
    private let customHome = "/Volumes/models/home"

    // MARK: - defaultHubPath

    func testDefaultHubPathFallsBackToUserCache() {
        XCTAssertEqual(
            HuggingFaceCache.defaultHubPath(environment: [:]),
            HuggingFaceCache.fallbackHubPath
        )
    }

    func testDefaultHubPathAppendsHubToHFHome() {
        XCTAssertEqual(
            HuggingFaceCache.defaultHubPath(environment: ["HF_HOME": customHome]),
            "\(customHome)/hub"
        )
    }

    func testDefaultHubPathToleratesHFHomeTrailingSlash() {
        XCTAssertEqual(
            HuggingFaceCache.defaultHubPath(environment: ["HF_HOME": "\(customHome)/"]),
            "\(customHome)/hub"
        )
    }

    func testDefaultHubPathPrefersHFHubCacheOverHFHome() {
        XCTAssertEqual(
            HuggingFaceCache.defaultHubPath(environment: [
                "HF_HUB_CACHE": customCache,
                "HF_HOME": customHome
            ]),
            customCache
        )
    }

    func testDefaultHubPathIgnoresBlankValues() {
        XCTAssertEqual(
            HuggingFaceCache.defaultHubPath(environment: [
                "HF_HUB_CACHE": "  ",
                "HF_HOME": "\n"
            ]),
            HuggingFaceCache.fallbackHubPath
        )
    }

    // MARK: - isConfigured

    func testIsConfiguredDetectsEitherVariable() {
        XCTAssertTrue(HuggingFaceCache.isConfigured(in: ["HF_HOME": customHome]))
        XCTAssertTrue(HuggingFaceCache.isConfigured(in: ["HF_HUB_CACHE": customCache]))
    }

    func testIsConfiguredIgnoresBlankAndMissingValues() {
        XCTAssertFalse(HuggingFaceCache.isConfigured(in: [:]))
        XCTAssertFalse(HuggingFaceCache.isConfigured(in: ["HF_HOME": "  ", "HF_HUB_CACHE": ""]))
    }

    // MARK: - resolvedSearchPath

    func testResolvedSearchPathUsesEnvironmentDefaultWhenUnset() {
        XCTAssertEqual(
            HuggingFaceCache.resolvedSearchPath(
                stored: nil,
                environment: ["HF_HOME": customHome]
            ),
            "\(customHome)/hub"
        )
        XCTAssertEqual(
            HuggingFaceCache.resolvedSearchPath(
                stored: "   ",
                environment: ["HF_HOME": customHome]
            ),
            "\(customHome)/hub"
        )
    }

    func testResolvedSearchPathMigratesLegacyDefault() {
        XCTAssertEqual(
            HuggingFaceCache.resolvedSearchPath(
                stored: HuggingFaceCache.fallbackHubPath,
                environment: ["HF_HOME": customHome]
            ),
            "\(customHome)/hub"
        )
    }

    func testResolvedSearchPathMigratesExpandedLegacyDefault() {
        let expanded = (HuggingFaceCache.fallbackHubPath as NSString).expandingTildeInPath
        XCTAssertEqual(
            HuggingFaceCache.resolvedSearchPath(
                stored: expanded,
                environment: ["HF_HUB_CACHE": customCache]
            ),
            customCache
        )
    }

    func testResolvedSearchPathKeepsLegacyDefaultWithoutEnvironmentOverride() {
        XCTAssertEqual(
            HuggingFaceCache.resolvedSearchPath(
                stored: HuggingFaceCache.fallbackHubPath,
                environment: [:]
            ),
            HuggingFaceCache.fallbackHubPath
        )
    }

    func testResolvedSearchPathKeepsCustomPath() {
        XCTAssertEqual(
            HuggingFaceCache.resolvedSearchPath(
                stored: "/elsewhere/models",
                environment: ["HF_HOME": customHome]
            ),
            "/elsewhere/models"
        )
    }
}

final class HuggingFaceAuthenticationTests: XCTestCase {
    func testTokenReadsAndTrimsHFToken() {
        XCTAssertEqual(
            HuggingFaceAuthentication.token(in: ["HF_TOKEN": "  hf_example\n"]),
            "hf_example"
        )
    }

    func testTokenIgnoresMissingAndBlankValues() {
        XCTAssertNil(HuggingFaceAuthentication.token(in: [:]))
        XCTAssertNil(HuggingFaceAuthentication.token(in: ["HF_TOKEN": " \n "]))
    }

    func testTokenInfoMasksCredentialAndShowsLength() {
        XCTAssertEqual(
            HuggingFaceAuthentication.tokenInfo(" hf_1234567890abcdef\n"),
            HuggingFaceTokenInfo(maskedValue: "hf_••••••••cdef", characterCount: 19)
        )
        XCTAssertEqual(
            HuggingFaceAuthentication.tokenInfo("short"),
            HuggingFaceTokenInfo(maskedValue: "••••••••", characterCount: 5)
        )
        XCTAssertNil(HuggingFaceAuthentication.tokenInfo(" \n "))
    }

    func testTokenMetadataDecodesNameAndPermission() throws {
        let data = Data(
            """
            {
              "auth": {
                "accessToken": {
                  "displayName": "localai",
                  "role": "write"
                }
              }
            }
            """.utf8
        )

        XCTAssertEqual(
            try HuggingFaceAuthentication.decodeTokenMetadata(from: data),
            HuggingFaceTokenMetadata(name: "localai", permission: "write")
        )
    }

    func testTokenMetadataToleratesMissingDetails() throws {
        XCTAssertEqual(
            try HuggingFaceAuthentication.decodeTokenMetadata(
                from: Data(#"{"auth":{"accessToken":{}}}"#.utf8)
            ),
            HuggingFaceTokenMetadata(name: nil, permission: nil)
        )
    }

    func testTokenMetadataCachePersistsForMatchingToken() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("HuggingFaceTokenMetadata.plist")
        defer {
            try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
        }
        let metadata = HuggingFaceTokenMetadata(name: "localai", permission: "write")

        try HuggingFaceTokenMetadataCache.save(
            metadata,
            for: "hf_example",
            to: cacheURL
        )

        XCTAssertEqual(
            HuggingFaceTokenMetadataCache.load(for: "hf_example", from: cacheURL),
            metadata
        )
        XCTAssertNil(
            HuggingFaceTokenMetadataCache.load(for: "hf_different", from: cacheURL)
        )
    }

    func testTokenMetadataCacheDoesNotPersistRawToken() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("HuggingFaceTokenMetadata.plist")
        defer {
            try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
        }

        try HuggingFaceTokenMetadataCache.save(
            HuggingFaceTokenMetadata(name: "token-name", permission: "read"),
            for: "hf_private_value",
            to: cacheURL
        )

        let storedData = try Data(contentsOf: cacheURL)
        XCTAssertFalse(String(decoding: storedData, as: UTF8.self).contains("hf_private_value"))
    }

    func testSystemCredentialPrefersEnvironmentToken() {
        var readCredentialFile = false

        let credential = HuggingFaceAuthentication.systemCredential(
            in: ["HF_TOKEN": " hf_environment "],
            homeDirectory: "/Users/example"
        ) { _ in
            readCredentialFile = true
            return "hf_file"
        }

        XCTAssertEqual(
            credential,
            HuggingFaceCredential(token: "hf_environment", source: .environment)
        )
        XCTAssertFalse(readCredentialFile)
    }

    func testSystemCredentialReadsLocalLoginToken() {
        var requestedPath: String?

        let credential = HuggingFaceAuthentication.systemCredential(
            in: [:],
            homeDirectory: "/Users/example"
        ) { path in
            requestedPath = path
            return "  hf_login\n"
        }

        XCTAssertEqual(requestedPath, "/Users/example/.cache/huggingface/token")
        XCTAssertEqual(
            credential,
            HuggingFaceCredential(
                token: "hf_login",
                source: .credentialFile,
                filePath: "/Users/example/.cache/huggingface/token"
            )
        )
    }

    func testSystemCredentialIgnoresMissingAndBlankLoginToken() {
        XCTAssertNil(
            HuggingFaceAuthentication.systemCredential(
                in: [:],
                homeDirectory: "/Users/example",
                readTokenFile: { _ in nil }
            )
        )
        XCTAssertNil(
            HuggingFaceAuthentication.systemCredential(
                in: [:],
                homeDirectory: "/Users/example",
                readTokenFile: { _ in " \n " }
            )
        )
    }

    func testCredentialFilePathUsesHuggingFacePrecedence() {
        let homeDirectory = "/Users/example"

        XCTAssertEqual(
            HuggingFaceAuthentication.credentialFilePath(
                environment: [
                    "HF_TOKEN_PATH": "~/credentials/hf-token",
                    "HF_HOME": "/Volumes/hugging-face",
                    "XDG_CACHE_HOME": "/Volumes/cache"
                ],
                homeDirectory: homeDirectory
            ),
            "/Users/example/credentials/hf-token"
        )
        XCTAssertEqual(
            HuggingFaceAuthentication.credentialFilePath(
                environment: [
                    "HF_HOME": "/Volumes/hugging-face",
                    "XDG_CACHE_HOME": "/Volumes/cache"
                ],
                homeDirectory: homeDirectory
            ),
            "/Volumes/hugging-face/token"
        )
        XCTAssertEqual(
            HuggingFaceAuthentication.credentialFilePath(
                environment: ["XDG_CACHE_HOME": "/Volumes/cache"],
                homeDirectory: homeDirectory
            ),
            "/Volumes/cache/huggingface/token"
        )
    }

    func testLoginWritesActiveAndNamedHuggingFaceCredentials() throws {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: homeURL)
        }

        let credential = try HuggingFaceAuthentication.logIn(
            token: "  hf_login_value\n",
            tokenName: "localai",
            environment: [:],
            homeDirectory: homeURL.path
        )
        let credentialURL = homeURL
            .appendingPathComponent(".cache/huggingface/token")
        let storedTokensURL = homeURL
            .appendingPathComponent(".cache/huggingface/stored_tokens")

        XCTAssertEqual(
            credential,
            HuggingFaceCredential(
                token: "hf_login_value",
                source: .credentialFile,
                filePath: credentialURL.path
            )
        )
        XCTAssertEqual(
            try String(contentsOf: credentialURL, encoding: .utf8),
            "hf_login_value"
        )
        XCTAssertEqual(
            try String(contentsOf: storedTokensURL, encoding: .utf8),
            """
            [localai]
            hf_token = hf_login_value

            """
        )
        XCTAssertEqual(
            try posixPermissions(at: credentialURL),
            0o600
        )
        XCTAssertEqual(
            try posixPermissions(at: storedTokensURL),
            0o600
        )
    }

    func testLoginPreservesOtherNamedHuggingFaceCredentials() throws {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: homeURL)
        }

        _ = try HuggingFaceAuthentication.logIn(
            token: "hf_first",
            tokenName: "alpha",
            environment: [:],
            homeDirectory: homeURL.path
        )
        _ = try HuggingFaceAuthentication.logIn(
            token: "hf_second",
            tokenName: "beta",
            environment: [:],
            homeDirectory: homeURL.path
        )

        let credentialsURL = homeURL
            .appendingPathComponent(".cache/huggingface")
        XCTAssertEqual(
            try String(
                contentsOf: credentialsURL.appendingPathComponent("token"),
                encoding: .utf8
            ),
            "hf_second"
        )
        XCTAssertEqual(
            try String(
                contentsOf: credentialsURL.appendingPathComponent("stored_tokens"),
                encoding: .utf8
            ),
            """
            [alpha]
            hf_token = hf_first

            [beta]
            hf_token = hf_second

            """
        )
    }

    func testLogoutRemovesCredentialFile() throws {
        var removedPath: String?
        let credential = HuggingFaceCredential(
            token: "hf_login",
            source: .credentialFile,
            filePath: "/Users/example/.cache/huggingface/token"
        )

        try HuggingFaceAuthentication.logOut(credential: credential) { path in
            removedPath = path
        }

        XCTAssertEqual(removedPath, "/Users/example/.cache/huggingface/token")
    }

    func testLogoutRejectsEnvironmentToken() {
        let credential = HuggingFaceCredential(
            token: "hf_environment",
            source: .environment
        )

        XCTAssertThrowsError(
            try HuggingFaceAuthentication.logOut(credential: credential)
        ) { error in
            XCTAssertEqual(
                error as? HuggingFaceAuthenticationError,
                .environmentTokenCannotBeRemoved
            )
        }
    }

    func testLogoutRejectsCredentialWithoutFilePath() {
        let credential = HuggingFaceCredential(
            token: "hf_login",
            source: .credentialFile
        )

        XCTAssertThrowsError(
            try HuggingFaceAuthentication.logOut(credential: credential)
        ) { error in
            XCTAssertEqual(
                error as? HuggingFaceAuthenticationError,
                .missingCredentialFile
            )
        }
    }

    func testCustomTokenOverridesEnvironmentToken() {
        XCTAssertEqual(
            HuggingFaceAuthentication.effectiveToken(
                customToken: "hf_custom",
                environmentToken: "hf_environment"
            ),
            "hf_custom"
        )
    }

    func testBlankCustomTokenFallsBackToEnvironmentToken() {
        XCTAssertEqual(
            HuggingFaceAuthentication.effectiveToken(
                customToken: "  ",
                environmentToken: "hf_environment"
            ),
            "hf_environment"
        )
    }

    func testAuthorizeAddsBearerHeader() {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models")!)
        HuggingFaceAuthentication.authorize(&request, token: " hf_example ")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_example")
    }

    func testAuthorizeIgnoresBlankToken() {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models")!)
        HuggingFaceAuthentication.authorize(&request, token: " ")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
