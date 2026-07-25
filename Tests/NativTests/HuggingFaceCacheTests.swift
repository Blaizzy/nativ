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

    func testTokenSummaryMasksCredentialAndShowsLength() {
        XCTAssertEqual(
            HuggingFaceAuthentication.tokenSummary(" hf_1234567890abcdef\n"),
            "hf_••••••••cdef · 19 characters"
        )
        XCTAssertEqual(
            HuggingFaceAuthentication.tokenSummary("short"),
            "•••••••• · 5 characters"
        )
        XCTAssertNil(HuggingFaceAuthentication.tokenSummary(" \n "))
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
            HuggingFaceCredential(token: "hf_login", source: .credentialFile)
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
}
