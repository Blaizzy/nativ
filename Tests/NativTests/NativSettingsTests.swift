import Darwin
import Network
import XCTest

@testable import NativServerKit

final class NativSettingsTests: XCTestCase {
    func testCachingAndCompactionDefaultsPreserveExplicitOptOuts() throws {
        for settings in [NativSettings(), try JSONDecoder().decode(NativSettings.self, from: Data("{}".utf8))] {
            XCTAssertTrue(settings.prefixCachingEnabled)
            XCTAssertTrue(settings.compactionEnabled)
            XCTAssertEqual(settings.launchEnvironment["APC_ENABLED"], "1")
        }
        let optedOut = NativSettings(compactionEnabled: false, prefixCachingEnabled: false)
        let restored = try PropertyListDecoder().decode(NativSettings.self, from: PropertyListEncoder().encode(optedOut))
        XCTAssertFalse(restored.prefixCachingEnabled)
        XCTAssertFalse(restored.compactionEnabled)
    }

    func testLiveInferenceSettingsDoNotRequireRestart() {
        let original = NativSettings()
        let changed = NativSettings(
            maxTokens: 4096, maxKVSize: 32768, compactionEnabled: false,
            kvQuantizationEnabled: true, kvBits: 3.5, kvGroupSize: 128,
            quantizedKVStart: 64, turboQuantEnabled: true,
            speculativeDecodingEnabled: true, draftModelID: "org/draft", draftKind: "mtp",
            prefixCachingEnabled: false, prefixCacheBlocks: 4096, prefixCacheBlockSize: 32
        )
        XCTAssertTrue(original.hasSameLaunchConfiguration(as: changed))
        XCTAssertTrue(changed.hasSameLaunchConfiguration(as: original))
        XCTAssertEqual(changed.runtimeSettings["apc_enabled"], .bool(false))
        XCTAssertEqual(changed.runtimeSettings["apc_num_blocks"], .number(4096))
        XCTAssertEqual(changed.runtimeSettings["apc_block_size"], .number(32))
        XCTAssertEqual(changed.runtimeSettings["kv_bits"], .number(3.5))
        XCTAssertEqual(changed.runtimeSettings["kv_quant_scheme"], .string("turboquant"))
        XCTAssertEqual(changed.runtimeSettings["max_kv_size"], .number(32768))
        XCTAssertEqual(changed.runtimeSettings["draft_model"], .string("org/draft"))
        XCTAssertEqual(original.runtimeSettings["kv_bits"], .null)
        XCTAssertEqual(original.runtimeSettings["draft_model"], .null)
        XCTAssertEqual(original.runtimeSettings["max_kv_size"], .number(0))
        XCTAssertNil(original.runtimeSettings["max_tokens"])
        var blockSizeChanged = changed
        blockSizeChanged.draftBlockSize = 8
        XCTAssertFalse(original.hasSameLaunchConfiguration(as: blockSizeChanged))
    }

    func testFormattingPreferencesRoundTripIndependentlyAndInjectOnlySelectedPrompts() throws {
        for emoji in NativPersonalization.EmojiUsage.allCases {
            for markdown in NativPersonalization.MarkdownUsage.allCases {
                var settings = NativSettings()
                settings.personalization.profile.emojiUsage = emoji
                settings.personalization.profile.markdownUsage = markdown
                let decoded = try PropertyListDecoder().decode(
                    NativSettings.self, from: PropertyListEncoder().encode(settings)
                )
                XCTAssertEqual(decoded.personalization.profile.emojiUsage, emoji)
                XCTAssertEqual(decoded.personalization.profile.markdownUsage, markdown)
                var expected: [String] = []
                if emoji != .default { expected.append("Emoji usage:\n" + emoji.systemPrompt) }
                if markdown != .default { expected.append("Markdown usage:\n" + markdown.systemPrompt) }
                XCTAssertEqual(decoded.personalization.systemPrompt, expected.joined(separator: "\n\n"))
            }
        }
    }

    func testMissingOrUnknownFormattingPreferencesUseModelDefaults() throws {
        for fields in ["", ",\"emojiUsage\":\"unknown\",\"markdownUsage\":\"unknown\""] {
            let data = Data("{\"preferredName\":\"Alex\",\"conversationStyle\":\"friendly\"\(fields)}".utf8)
            let profile = try JSONDecoder().decode(NativPersonalization.Profile.self, from: data)
            XCTAssertEqual(profile.emojiUsage, .default)
            XCTAssertEqual(profile.markdownUsage, .default)
            XCTAssertEqual(profile.conversationStyle, .friendly)
            XCTAssertEqual(profile.preferredName, "Alex")
        }
    }

    func testPersonalInfoFieldsAreLimitedTo200CharactersIncludingUnicode() throws {
        let text = "First line\n" + String(repeating: "👩🏽‍💻", count: 210)
        let expected = String(text.prefix(200))
        let profile = NativPersonalization.Profile(
            preferredName: text, occupation: text, conversationStyle: .friendly, aboutYou: text
        )
        XCTAssertEqual(profile.preferredName, expected)
        XCTAssertEqual(profile.occupation, expected)
        XCTAssertEqual(profile.aboutYou, expected)
        XCTAssertEqual(profile.aboutYou.count, 200)
        XCTAssertTrue(profile.aboutYou.contains("\n"))

        let data = try JSONSerialization.data(withJSONObject: [
            "preferredName": text, "occupation": text, "aboutYou": text,
            "conversationStyle": "friendly",
        ])
        var decoded = try JSONDecoder().decode(NativPersonalization.Profile.self, from: data)
        XCTAssertEqual(decoded, profile)
        decoded.aboutYou = text
        decoded.limitFieldLengths()
        XCTAssertEqual(decoded, profile)
    }

    func testConversationStylesRoundTripAndOnlySelectedPromptIsIncluded() throws {
        for style in NativPersonalization.ConversationStyle.allCases {
            var settings = NativSettings()
            settings.personalization.profile.conversationStyle = style
            let decoded = try PropertyListDecoder().decode(
                NativSettings.self, from: PropertyListEncoder().encode(settings)
            )
            XCTAssertEqual(decoded.personalization.profile.conversationStyle, style)
            if style == .default {
                XCTAssertTrue(decoded.personalization.systemPrompt.isEmpty)
            } else {
                XCTAssertEqual(decoded.personalization.systemPrompt, "Conversation style:\n" + style.systemPrompt)
            }
        }
    }

    func testMissingOrUnknownConversationStyleDefaultsWithoutLosingProfile() throws {
        for styleField in ["\"responseStyle\":\"Old custom style\"", "\"conversationStyle\":\"unknown\""] {
            let data = Data("{\"preferredName\":\"Alex\",\"occupation\":\"Designer\",\"aboutYou\":\"Lives in Paris\",\(styleField)}".utf8)
            let profile = try JSONDecoder().decode(NativPersonalization.Profile.self, from: data)
            XCTAssertEqual(profile.conversationStyle, .default)
            XCTAssertEqual(profile.preferredName, "Alex")
            XCTAssertEqual(profile.occupation, "Designer")
            XCTAssertEqual(profile.aboutYou, "Lives in Paris")
        }
    }

    func testPersonalizationRoundTripsSeparatelyFromSystemPrompt() throws {
        var settings = NativSettings(systemPrompt: "Existing instructions")
        settings.personalization.profile = .init(
            preferredName: "Alex", occupation: "Designer",
            conversationStyle: .concise, aboutYou: "Lives in Paris"
        )
        let decoded = try PropertyListDecoder().decode(
            NativSettings.self, from: PropertyListEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.personalization, settings.personalization)
        XCTAssertEqual(decoded.systemPrompt, "Existing instructions")
        XCTAssertTrue(settings.hasSameLaunchConfiguration(as: NativSettings(systemPrompt: "Existing instructions")))
    }

    func testLegacySettingsHaveEmptyPersonalization() throws {
        let settings = try JSONDecoder().decode(NativSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.personalization, NativPersonalization())
        XCTAssertTrue(settings.personalization.systemPrompt.isEmpty)
    }

    func testPinnedModelsRoundTripInOrder() throws {
        let settings = NativSettings(
            pinnedModelIDs: ["org/most-used", "org/second"]
        )

        let data = try PropertyListEncoder().encode(settings)
        let decoded = try PropertyListDecoder().decode(NativSettings.self, from: data)

        XCTAssertEqual(decoded.pinnedModelIDs, ["org/most-used", "org/second"])
    }

    func testPinnedModelsNormalizeWhitespaceAndDuplicates() {
        let settings = NativSettings(
            pinnedModelIDs: [" org/model ", "", "org/model", "org/other"]
        ).normalized()

        XCTAssertEqual(settings.pinnedModelIDs, ["org/model", "org/other"])
    }

    func testMissingPinnedModelsDecodeAsEmptyForBackwardCompatibility() throws {
        let settings = try PropertyListDecoder().decode(
            NativSettings.self,
            from: PropertyListSerialization.data(
                fromPropertyList: ["modelSearchPath": NativSettings.defaultModelSearchPath],
                format: .xml,
                options: 0
            )
        )

        XCTAssertTrue(settings.pinnedModelIDs.isEmpty)
    }

    func testDisablingLegacyReadFileAlsoDisablesGroupedSearchTool() {
        let settings = NativSettings(disabledToolNames: ["read_file"]).normalized()

        XCTAssertFalse(settings.isToolEnabled("read_file"))
        XCTAssertFalse(settings.isToolEnabled("search_files"))
    }

    func testFileReadRootRoundTripsAndNormalizesWhitespace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settings = NativSettings(fileReadRootPath: "  \(directory.path)  ")
            .normalized()

        XCTAssertEqual(settings.fileReadRootPath, directory.path)

        let data = try PropertyListEncoder().encode(settings)
        let decoded = try PropertyListDecoder().decode(NativSettings.self, from: data)
        XCTAssertEqual(decoded.fileReadRootPath, directory.path)
    }

    func testFileWriteRootRoundTripsAndNormalizesWhitespace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settings = NativSettings(fileWriteRootPath: "  \(directory.path)  ")
            .normalized()

        XCTAssertEqual(settings.fileWriteRootPath, directory.path)

        let data = try PropertyListEncoder().encode(settings)
        let decoded = try PropertyListDecoder().decode(NativSettings.self, from: data)
        XCTAssertEqual(decoded.fileWriteRootPath, directory.path)
    }

    func testToolsAreEnabledByDefaultAndCanBeDisabled() throws {
        var settings = NativSettings()

        XCTAssertTrue(settings.isToolEnabled("get_system_stats"))

        settings.setToolEnabled(false, toolName: "get_system_stats")
        XCTAssertFalse(settings.isToolEnabled("get_system_stats"))
        XCTAssertEqual(settings.disabledToolNames, ["get_system_stats"])

        settings = try PropertyListDecoder().decode(
            NativSettings.self,
            from: PropertyListEncoder().encode(settings)
        )
        XCTAssertFalse(settings.isToolEnabled("get_system_stats"))

        settings.setToolEnabled(true, toolName: "get_system_stats")
        XCTAssertTrue(settings.isToolEnabled("get_system_stats"))
        XCTAssertTrue(settings.disabledToolNames.isEmpty)
    }

    func testDisablingAToolDoesNotCreateDuplicatePreferences() {
        var settings = NativSettings()

        settings.setToolEnabled(false, toolName: "get_system_stats")
        settings.setToolEnabled(false, toolName: "get_system_stats")

        XCTAssertEqual(settings.disabledToolNames, ["get_system_stats"])
    }

    func testLocalModelSearchPathsIncludeNormalizedAdditionalFolders() {
        let settings = NativSettings(
            modelSearchPath: "~/managed-models",
            additionalModelSearchPaths: [" ~/external-models ", "~/external-models", " "]
        )

        XCTAssertEqual(
            settings.localModelSearchPaths,
            LocalModelSearchPaths(
                primary: "~/managed-models",
                additional: ["~/external-models"]
            )
        )
    }

    func testLaunchArgumentsRouteEachPreloadedModelToItsOwnFlag() {
        let settings = NativSettings(
            languageModelID: "org/language",
            imageGenerationModelID: "org/image",
            textToSpeechModelID: "org/tts",
            speechToTextModelID: "org/stt",
            embeddingModelID: "org/embed"
        )

        XCTAssertEqual(
            Array(settings.launchArguments.prefix(12)),
            [
                "--host", "127.0.0.1",
                "--port", "8080",
                "--max-tokens", "2048",
                "--model", "org/language",
                "--image-model", "org/image",
                "--tts-model", "org/tts",
            ]
        )
        XCTAssertTrue(
            settings.launchArguments.containsAdjacent(
                "--stt-model",
                "org/stt"
            )
        )
        if NativSettings.serverSupportsEmbeddingModelArgument {
            XCTAssertTrue(
                settings.launchArguments.containsAdjacent(
                    "--embedding-model",
                    "org/embed"
                )
            )
        } else {
            XCTAssertFalse(settings.launchArguments.contains("--embedding-model"))
        }
    }

    func testEmptyPreloadSelectionsAreOmitted() {
        let settings = NativSettings(
            languageModelID: " ",
            imageGenerationModelID: "",
            textToSpeechModelID: "\n",
            speechToTextModelID: nil,
            embeddingModelID: "  "
        )

        XCTAssertFalse(settings.launchArguments.contains("--model"))
        XCTAssertFalse(settings.launchArguments.contains("--image-model"))
        XCTAssertFalse(settings.launchArguments.contains("--tts-model"))
        XCTAssertFalse(settings.launchArguments.contains("--stt-model"))
        XCTAssertFalse(settings.launchArguments.contains("--embedding-model"))
    }

    func testEmbeddingModelSlotRoundTripsAndRequiresRestart() throws {
        var settings = NativSettings()
        settings.setModelID("org/embed", for: .embeddings)
        XCTAssertEqual(settings.modelID(for: .embeddings), "org/embed")
        XCTAssertEqual(settings.embeddingModelID, "org/embed")

        let decoded = try JSONDecoder().decode(
            NativSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.embeddingModelID, "org/embed")
        XCTAssertFalse(settings.hasSameLaunchConfiguration(as: NativSettings()))
    }

    func testImageEditModelIsNotPassedToGenerationPreloadFlag() {
        let settings = NativSettings(
            imageGenerationModelID: "microsoft/Mage-Flow-Edit-Turbo"
        )

        XCTAssertNil(settings.normalized().imageGenerationModelID)
        XCTAssertFalse(settings.launchArguments.contains("--image-model"))
    }

    func testServerHostIsNormalizedAndPassedToServer() {
        let settings = NativSettings(serverHost: "  0.0.0.0  ", serverPort: 9_001)

        XCTAssertEqual(settings.normalized().serverHost, "0.0.0.0")
        XCTAssertEqual(settings.serverBaseURL.absoluteString, "http://127.0.0.1:9001")
        XCTAssertTrue(settings.launchArguments.containsAdjacent("--host", "0.0.0.0"))
    }

    func testWildcardIPv6HostConnectsOverLoopback() {
        let settings = NativSettings(serverHost: "::", serverPort: 9_003)

        XCTAssertEqual(settings.normalized().serverHost, "::")
        XCTAssertEqual(settings.serverBaseURL.absoluteString, "http://[::1]:9003")
        XCTAssertTrue(settings.launchArguments.containsAdjacent("--host", "::"))
    }

    func testIPv6ServerHostProducesValidBaseURL() {
        let settings = NativSettings(serverHost: "[::1]", serverPort: 9_002)

        XCTAssertEqual(settings.normalized().serverHost, "::1")
        XCTAssertEqual(settings.serverBaseURL.absoluteString, "http://[::1]:9002")
        XCTAssertTrue(settings.launchArguments.containsAdjacent("--host", "::1"))
    }

    func testMissingServerHostUsesLoopbackDefault() throws {
        let settings = try JSONDecoder().decode(NativSettings.self, from: Data("{}".utf8))

        XCTAssertEqual(settings.serverHost, "127.0.0.1")
    }

    func testServerHostRequiresServerRestart() {
        let original = NativSettings()
        var changed = original
        changed.serverHost = "0.0.0.0"

        XCTAssertFalse(original.hasSameLaunchConfiguration(as: changed))
    }

    func testServerAPITokenIsNormalizedMaskedAndPassedToServer() {
        let settings = NativSettings(serverAPIKey: "  nativ_1234567890abcdef\n")
        let normalized = settings.normalized()

        XCTAssertEqual(normalized.serverAPIKey, "nativ_1234567890abcdef")
        XCTAssertEqual(
            ServerAPIAuthentication.tokenInfo(normalized.serverAPIKey),
            ServerAPITokenInfo(
                maskedValue: "nativ_••••••••cdef",
                characterCount: 22
            )
        )
        XCTAssertEqual(
            normalized.launchEnvironment["MLX_VLM_SERVER_API_KEY"],
            "nativ_1234567890abcdef"
        )
    }

    func testBlankServerAPITokenIsOmitted() {
        let settings = NativSettings(serverAPIKey: " \n ").normalized()

        XCTAssertNil(settings.serverAPIKey)
        XCTAssertNil(settings.launchEnvironment["MLX_VLM_SERVER_API_KEY"])
    }

    func testGeneratedServerAPITokenHasNativPrefix() {
        let token = ServerAPIAuthentication.generateToken()

        XCTAssertTrue(token.hasPrefix("nativ_"))
        XCTAssertEqual(token, ServerAPIAuthentication.normalizedToken(token))
    }

    func testServerAPIKeyIsOmittedFromEncodedSettings() throws {
        let data = try PropertyListEncoder().encode(
            NativSettings(serverAPIKey: "nativ_secret")
        )
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertNil(propertyList["serverAPIKey"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("nativ_secret"))
    }

    func testSavingSettingsStoresServerAPIKeyInCredentialStore() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentialStore = TestServerAPICredentialStore()

        NativSettings(serverAPIKey: "  nativ_secret\n").save(
            to: url,
            credentialStore: credentialStore
        )

        XCTAssertEqual(credentialStore.token, "nativ_secret")
        XCTAssertEqual(try propertyList(at: url)["serverAPIKey"] as? String, nil)
        XCTAssertEqual(
            NativSettings.load(from: url, credentialStore: credentialStore).serverAPIKey,
            "nativ_secret"
        )
    }

    func testSavingWritesPropertyListEvenWhenCredentialStoreFails() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentialStore = TestServerAPICredentialStore(
            saveError: TestCredentialStoreError.unavailable
        )

        NativSettings(languageModelID: "org/model").save(
            to: url,
            credentialStore: credentialStore
        )

        XCTAssertEqual(
            try propertyList(at: url)["languageModelID"] as? String,
            "org/model",
            "a Keychain failure must not block persisting the rest of settings to disk"
        )
    }

    func testLoadingMigratesLegacyServerAPIKeyIntoCredentialStore() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacySettings(serverAPIKey: "  nativ_legacy\n", to: url)
        let credentialStore = TestServerAPICredentialStore()

        let settings = NativSettings.load(from: url, credentialStore: credentialStore)

        XCTAssertEqual(settings.serverAPIKey, "nativ_legacy")
        XCTAssertEqual(credentialStore.token, "nativ_legacy")
        XCTAssertNil(try propertyList(at: url)["serverAPIKey"])
    }

    func testFailedLegacyMigrationRetainsRecoverableCredential() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacySettings(serverAPIKey: "nativ_legacy", to: url)
        let credentialStore = TestServerAPICredentialStore(
            saveError: TestCredentialStoreError.unavailable
        )

        let settings = NativSettings.load(from: url, credentialStore: credentialStore)

        XCTAssertEqual(settings.serverAPIKey, "nativ_legacy")
        XCTAssertEqual(
            try propertyList(at: url)["serverAPIKey"] as? String,
            "nativ_legacy"
        )
    }

    func testKeychainCredentialTakesPrecedenceOverLegacyCredential() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacySettings(serverAPIKey: "nativ_legacy", to: url)
        let credentialStore = TestServerAPICredentialStore(token: "nativ_keychain")

        let settings = NativSettings.load(from: url, credentialStore: credentialStore)

        XCTAssertEqual(settings.serverAPIKey, "nativ_keychain")
        XCTAssertEqual(credentialStore.token, "nativ_keychain")
        XCTAssertNil(try propertyList(at: url)["serverAPIKey"])
    }

    func testHuggingFaceTokenIsOmittedFromEncodedSettings() throws {
        let data = try PropertyListEncoder().encode(
            NativSettings(huggingFaceToken: "hf_secret")
        )
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertNil(propertyList["huggingFaceToken"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hf_secret"))
    }

    func testSavingSettingsStoresHuggingFaceTokenInCredentialStore() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let credentialStore = TestServerAPICredentialStore()

        NativSettings(huggingFaceToken: "  hf_secret\n").save(
            to: url,
            huggingFaceStore: credentialStore
        )

        XCTAssertEqual(credentialStore.token, "hf_secret")
        XCTAssertNil(try propertyList(at: url)["huggingFaceToken"] as? String)
    }

    func testSavingWritesPropertyListEvenWhenHuggingFaceStoreFails() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let huggingFaceStore = TestServerAPICredentialStore(
            saveError: TestCredentialStoreError.unavailable
        )

        NativSettings(languageModelID: "org/model").save(
            to: url,
            huggingFaceStore: huggingFaceStore
        )

        XCTAssertEqual(
            try propertyList(at: url)["languageModelID"] as? String,
            "org/model",
            "a Keychain failure must not block persisting the rest of settings to disk"
        )
    }

    func testLoadingMigratesLegacyHuggingFaceTokenIntoCredentialStore() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacySettings(huggingFaceToken: "hf_legacy", to: url)
        let credentialStore = TestServerAPICredentialStore()

        let settings = NativSettings.load(from: url, huggingFaceStore: credentialStore)

        XCTAssertEqual(settings.huggingFaceToken, "hf_legacy")
        XCTAssertEqual(credentialStore.token, "hf_legacy")
        XCTAssertNil(try propertyList(at: url)["huggingFaceToken"])
    }

    func testFailedHuggingFaceMigrationRetainsRecoverableToken() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacySettings(huggingFaceToken: "hf_legacy", to: url)
        let credentialStore = TestServerAPICredentialStore(
            saveError: TestCredentialStoreError.unavailable
        )

        let settings = NativSettings.load(from: url, huggingFaceStore: credentialStore)

        XCTAssertEqual(settings.huggingFaceToken, "hf_legacy")
        XCTAssertEqual(
            try propertyList(at: url)["huggingFaceToken"] as? String,
            "hf_legacy"
        )
    }

    func testHuggingFaceCredentialTakesPrecedenceOverLegacyToken() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeLegacySettings(huggingFaceToken: "hf_legacy", to: url)
        let credentialStore = TestServerAPICredentialStore(token: "hf_keychain")

        let settings = NativSettings.load(from: url, huggingFaceStore: credentialStore)

        XCTAssertEqual(settings.huggingFaceToken, "hf_keychain")
        XCTAssertEqual(credentialStore.token, "hf_keychain")
        XCTAssertNil(try propertyList(at: url)["huggingFaceToken"])
    }

    func testServerAuthorizationAddsBearerHeader() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/health")!)

        NativServerAuthorization.authorize(&request, apiKey: "  nativ_test_token\n")

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer nativ_test_token"
        )
    }

    func testServerAuthorizationOmitsBlankToken() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/health")!)

        NativServerAuthorization.authorize(&request, apiKey: " \n ")

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testChatClientConfiguresRequest() throws {
        let client = NativChatClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: "nativ_chat_token"
        )
        let payload = MLXChatCompletionRequest(
            model: "org/model",
            messages: [MLXChatMessage(role: "user", content: "Hello")],
            maxTokens: 1,
            temperature: 0,
            topK: 0,
            topP: 1,
            minP: 0
        )

        let request = try client.makeURLRequest(payload: payload, accepts: "application/json")

        XCTAssertEqual(request.timeoutInterval, 600)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer nativ_chat_token"
        )
    }

    func testPromptTokenCountRequestUsesServerTokenizerEndpoint() throws {
        let client = NativChatClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: "nativ_chat_token"
        )
        let payload = MLXChatCompletionRequest(
            model: "org/model",
            messages: [MLXChatMessage(role: "user", content: "Hello")],
            maxTokens: 512,
            temperature: 0,
            topK: 0,
            topP: 1,
            minP: 0,
            enableThinking: true
        )

        let request = try client.makePromptTokenCountURLRequest(for: payload)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(request.url?.path, "/v1/responses/input_tokens")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer nativ_chat_token")
        XCTAssertEqual(json["model"] as? String, "org/model")
        XCTAssertEqual(json["enable_thinking"] as? Bool, true)
        XCTAssertNil(json["max_tokens"])
    }

    func testImageClientAddsServerAuthorization() throws {
        let client = NativImageClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: "nativ_image_token"
        )
        let payload = MLXImageGenerationRequest(model: "org/model", prompt: "A lighthouse")

        let request = try client.makeURLRequest(payload, path: "v1/images/generations")

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer nativ_image_token"
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "org/model")
    }

    func testEveryPreloadSelectionRequiresServerRestart() {
        let original = NativSettings()

        for slot in ModelPreloadSlot.allCases {
            var changed = original
            changed.setModelID("org/model", for: slot)

            XCTAssertFalse(
                original.hasSameLaunchConfiguration(as: changed),
                "\(slot.displayName) should participate in restart detection"
            )
        }
    }

    func testCrossKindSelectionWarnsWhenCombinedModelsExceedBudget() {
        let warning = ModelPreloadMemoryWarning.evaluate(
            candidateModelID: "org/image",
            candidateSlot: .imageGeneration,
            currentSelections: [.language: "org/language"],
            workingSetBytesByModelID: [
                "org/language": 60,
                "org/image": 50,
            ],
            memoryBudgetBytes: 100,
            totalMemoryBytes: 125
        )

        XCTAssertEqual(warning?.existingSlots, [.language])
        XCTAssertEqual(warning?.estimatedWorkingSetBytes, 110)
    }

    func testSameKindReplacementDoesNotWarn() {
        let warning = ModelPreloadMemoryWarning.evaluate(
            candidateModelID: "org/new-language",
            candidateSlot: .language,
            currentSelections: [.language: "org/old-language"],
            workingSetBytesByModelID: [
                "org/old-language": 80,
                "org/new-language": 80,
            ],
            memoryBudgetBytes: 100,
            totalMemoryBytes: 125
        )

        XCTAssertNil(warning)
    }

    func testReplacementExcludesPreviousModelInSameSlot() {
        let warning = ModelPreloadMemoryWarning.evaluate(
            candidateModelID: "org/new-language",
            candidateSlot: .language,
            currentSelections: [
                .language: "org/old-language",
                .imageGeneration: "org/image",
            ],
            workingSetBytesByModelID: [
                "org/old-language": 80,
                "org/new-language": 50,
                "org/image": 40,
            ],
            memoryBudgetBytes: 100,
            totalMemoryBytes: 125
        )

        XCTAssertNil(warning)
    }

    func testModelSelectedForTwoKindsIsCountedOnce() {
        let warning = ModelPreloadMemoryWarning.evaluate(
            candidateModelID: "org/multimodal",
            candidateSlot: .imageGeneration,
            currentSelections: [.language: "org/multimodal"],
            workingSetBytesByModelID: ["org/multimodal": 90],
            memoryBudgetBytes: 80,
            totalMemoryBytes: 100
        )

        XCTAssertEqual(warning?.estimatedWorkingSetBytes, 90)
    }

    func testChatFontScaleStepsClampAndReset() {
        var settings = NativSettings()
        XCTAssertEqual(settings.chatFontScale, 1.0)
        settings.stepChatFontScale(by: 1)
        XCTAssertEqual(settings.chatFontScale, 1.15)
        settings.stepChatFontScale(by: -5)
        XCTAssertEqual(settings.chatFontScale, NativSettings.minChatFontScale)
        settings.stepChatFontScale(by: 99)
        XCTAssertEqual(settings.chatFontScale, NativSettings.maxChatFontScale)
        settings.resetChatFontScale()
        XCTAssertEqual(settings.chatFontScale, 1.0)
    }

    func testChatFontScaleRoundTripsAndClamps() throws {
        var settings = NativSettings()
        settings.chatFontScale = 1.3
        let decoded = try JSONDecoder().decode(
            NativSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.chatFontScale, 1.3)

        var extreme = NativSettings()
        extreme.chatFontScale = 9.0
        XCTAssertEqual(extreme.normalized().chatFontScale, NativSettings.maxChatFontScale)
    }

    func testSidebarSectionCollapseRoundTrips() throws {
        var settings = NativSettings()
        XCTAssertFalse(settings.sidebarPinnedCollapsed)
        XCTAssertFalse(settings.sidebarProjectsCollapsed)
        XCTAssertFalse(settings.sidebarSessionsCollapsed)
        XCTAssertFalse(settings.allSidebarSectionsCollapsed)

        settings.sidebarPinnedCollapsed = true
        settings.sidebarProjectsCollapsed = true
        settings.sidebarSessionsCollapsed = true
        let decoded = try JSONDecoder().decode(
            NativSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.sidebarPinnedCollapsed)
        XCTAssertTrue(decoded.sidebarProjectsCollapsed)
        XCTAssertTrue(decoded.sidebarSessionsCollapsed)
        XCTAssertTrue(decoded.allSidebarSectionsCollapsed)
    }

    func testSetAllSidebarSectionsCollapsedTogglesEveryFlag() {
        var settings = NativSettings()
        settings.setAllSidebarSectionsCollapsed(true)
        XCTAssertTrue(settings.sidebarPinnedCollapsed)
        XCTAssertTrue(settings.sidebarProjectsCollapsed)
        XCTAssertTrue(settings.sidebarSessionsCollapsed)
        XCTAssertTrue(settings.allSidebarSectionsCollapsed)

        settings.setAllSidebarSectionsCollapsed(false)
        XCTAssertFalse(settings.sidebarPinnedCollapsed)
        XCTAssertFalse(settings.sidebarProjectsCollapsed)
        XCTAssertFalse(settings.sidebarSessionsCollapsed)
        XCTAssertFalse(settings.allSidebarSectionsCollapsed)
    }

    func testSidebarSectionCollapseDefaultsToExpandedForExistingInstalls() throws {
        let legacyJSON = Data(#"{"serverHost":"127.0.0.1","serverPort":8080}"#.utf8)
        let decoded = try JSONDecoder().decode(NativSettings.self, from: legacyJSON)
        XCTAssertFalse(decoded.sidebarPinnedCollapsed)
        XCTAssertFalse(decoded.sidebarProjectsCollapsed)
        XCTAssertFalse(decoded.sidebarSessionsCollapsed)
    }

    func testProjectToolsDefaultToEnabledAndRoundTripIndependently() throws {
        XCTAssertTrue(NativSettings().projectToolsEnabled)

        var settings = NativSettings()
        settings.projectToolsEnabled = false
        settings.disabledToolNames = ["terminal"]
        let decoded = try JSONDecoder().decode(
            NativSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertFalse(decoded.projectToolsEnabled)
        XCTAssertEqual(decoded.disabledToolNames, ["terminal"])
    }

    func testRememberProfileCapturesCurrentModelSettings() throws {
        var settings = NativSettings()
        settings.thinkingEnabled = true
        settings.thinkingBudgetEnabled = true
        settings.thinkingBudget = 1_024
        settings.speculativeDecodingEnabled = true
        settings.draftModelID = "org/drafter"
        settings.draftKind = "mtp"

        settings.rememberProfile(forModel: "org/main")

        let profile = try XCTUnwrap(settings.modelProfile(for: "org/main"))
        XCTAssertTrue(profile.thinkingEnabled)
        XCTAssertTrue(profile.thinkingBudgetEnabled)
        XCTAssertEqual(profile.thinkingBudget, 1_024)
        XCTAssertTrue(profile.speculativeDecodingEnabled)
        XCTAssertEqual(profile.draftModelID, "org/drafter")
        XCTAssertEqual(profile.draftKind, "mtp")
    }

    func testApplyProfileRestoresSavedValues() {
        var settings = NativSettings()
        settings.applyProfile(
            ModelConfigProfile(
                thinkingEnabled: false,
                thinkingBudgetEnabled: true,
                thinkingBudget: 2_048,
                speculativeDecodingEnabled: true,
                draftModelID: "org/drafter",
                draftKind: "ngram"
            )
        )

        XCTAssertFalse(settings.thinkingEnabled)
        XCTAssertTrue(settings.thinkingBudgetEnabled)
        XCTAssertEqual(settings.thinkingBudget, 2_048)
        XCTAssertTrue(settings.speculativeDecodingEnabled)
        XCTAssertEqual(settings.draftModelID, "org/drafter")
        XCTAssertEqual(settings.draftKind, "ngram")
    }

    func testModelConfigsRoundTripThroughCoding() throws {
        var settings = NativSettings()
        settings.thinkingEnabled = true
        settings.draftModelID = "org/drafter"
        settings.rememberProfile(forModel: "org/main")

        let decoded = try JSONDecoder().decode(
            NativSettings.self,
            from: JSONEncoder().encode(settings)
        )

        let profile = try XCTUnwrap(decoded.modelProfile(for: "org/main"))
        XCTAssertTrue(profile.thinkingEnabled)
        XCTAssertEqual(profile.draftModelID, "org/drafter")
    }

    func testModelProfileIsNilForUnconfiguredModel() {
        XCTAssertNil(NativSettings().modelProfile(for: "org/never-configured"))
    }

    func testRememberProfileIgnoresEmptyModelID() {
        var settings = NativSettings()
        settings.thinkingEnabled = true
        settings.rememberProfile(forModel: "")

        XCTAssertTrue(settings.modelConfigs.isEmpty)
    }

    func testModelConfigsAreExportedToServerLaunchEnvironment() throws {
        var settings = NativSettings()
        settings.thinkingEnabled = true
        settings.thinkingBudgetEnabled = true
        settings.thinkingBudget = 1_024
        settings.rememberProfile(forModel: "org/main")

        let json = try XCTUnwrap(settings.launchEnvironment["NATIV_MODEL_CONFIGS"])
        let decoded = try JSONDecoder().decode(
            [String: ModelConfigProfile].self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded["org/main"]?.thinkingEnabled, true)
        XCTAssertEqual(decoded["org/main"]?.thinkingBudget, 1_024)
    }

    func testLaunchEnvironmentOmitsModelConfigsWhenEmpty() {
        XCTAssertNil(NativSettings().launchEnvironment["NATIV_MODEL_CONFIGS"])
    }

    private func temporarySettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("settings.plist")
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
    }

    private func writeLegacySettings(
        serverAPIKey: String? = nil,
        huggingFaceToken: String? = nil,
        to url: URL
    ) throws {
        let encoded = try PropertyListEncoder().encode(NativSettings())
        var propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: encoded,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        if let serverAPIKey {
            propertyList["serverAPIKey"] = serverAPIKey
        }
        if let huggingFaceToken {
            propertyList["huggingFaceToken"] = huggingFaceToken
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}

private enum TestCredentialStoreError: Error {
    case unavailable
}

private final class TestServerAPICredentialStore: ServerAPICredentialStoring,
    HuggingFaceCredentialStoring
{
    var token: String?
    var loadError: Error?
    var saveError: Error?

    init(
        token: String? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.token = token
        self.loadError = loadError
        self.saveError = saveError
    }

    func load() throws -> String? {
        if let loadError {
            throw loadError
        }
        return token
    }

    func save(_ token: String?) throws {
        if let saveError {
            throw saveError
        }
        self.token = token
    }
}

final class NativChatToolProtocolTests: XCTestCase {
    func testChatRequestEncodesImageToolAndToolChoice() throws {
        let tool = MLXChatToolDefinition(
            function: MLXChatFunctionDefinition(
                name: "generate_image",
                description: "Generate an image",
                parameters: .object([
                    "type": .string("object"),
                    "required": .array([.string("prompt")]),
                ])
            ))
        let request = MLXChatCompletionRequest(
            model: "org/language",
            messages: [MLXChatMessage(role: "user", content: "Draw a lighthouse")],
            maxTokens: 512,
            temperature: 0.7,
            topK: 0,
            topP: 0.95,
            minP: 0,
            tools: [tool],
            toolChoice: "auto"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "generate_image")
    }

    func testToolCallAndResultMessagesRoundTrip() throws {
        let call = MLXChatToolCall(
            id: "call_123",
            function: MLXChatFunctionCall(
                name: "generate_image",
                arguments: #"{"prompt":"A lighthouse"}"#
            )
        )
        let messages = [
            MLXChatMessage(
                role: "assistant",
                content: nil as String?,
                toolCalls: [call]
            ),
            MLXChatMessage(
                role: "tool",
                content: #"{"ok":true}"#,
                toolCallID: "call_123",
                name: "generate_image"
            ),
        ]

        let data = try JSONEncoder().encode(messages)
        XCTAssertEqual(try JSONDecoder().decode([MLXChatMessage].self, from: data), messages)
    }

    func testToolCallArgumentsAcceptObjectFormAndMissingDeltaRole() throws {
        let data = Data(
            #"""
            {
              "tool_calls": [{
                "index": 0,
                "id": "call_123",
                "type": "function",
                "function": {
                  "name": "generate_image",
                  "arguments": {"prompt": "A lighthouse"}
                }
              }]
            }
            """#.utf8
        )

        let message = try JSONDecoder().decode(MLXChatMessage.self, from: data)
        XCTAssertEqual(message.role, "assistant")
        XCTAssertEqual(message.toolCalls?.first?.function?.name, "generate_image")
        XCTAssertTrue(
            message.toolCalls?.first?.function?.arguments?.contains("A lighthouse") == true)
    }

    func testFragmentedToolCallsAccumulateByIndex() {
        var accumulator = MLXChatToolCallAccumulator()
        accumulator.merge([
            MLXChatToolCall(
                index: 0,
                id: "call_123",
                function: MLXChatFunctionCall(
                    name: "generate_image",
                    arguments: #"{"prompt":"A "#
                )
            )
        ])
        accumulator.merge([
            MLXChatToolCall(
                index: 0,
                id: nil,
                type: nil,
                function: MLXChatFunctionCall(
                    name: nil,
                    arguments: #"lighthouse"}"#
                )
            )
        ])

        XCTAssertEqual(accumulator.toolCalls.count, 1)
        XCTAssertEqual(accumulator.toolCalls[0].id, "call_123")
        XCTAssertEqual(accumulator.toolCalls[0].function?.name, "generate_image")
        XCTAssertEqual(
            accumulator.toolCalls[0].function?.arguments,
            #"{"prompt":"A lighthouse"}"#
        )
    }

    func testServerErrorMessageExtractsFastAPIDetail() {
        let body =
            #"{"detail":"Failed to load model: Model type bert not supported."}"#

        XCTAssertEqual(
            NativServerErrorMessage.detail(from: body),
            "Failed to load model: Model type bert not supported."
        )
        XCTAssertEqual(
            NativChatError.httpStatus(400, body).localizedDescription,
            "Failed to load model: Model type bert not supported."
        )
        XCTAssertEqual(
            NativImageError.httpStatus(400, body).localizedDescription,
            "Failed to load model: Model type bert not supported."
        )
    }

    func testServerErrorMessagePreservesHTTPFallback() {
        XCTAssertEqual(
            NativServerErrorMessage.endpointFailure(
                endpoint: "Chat endpoint",
                statusCode: 503,
                responseBody: ""
            ),
            "Chat endpoint returned HTTP 503"
        )
        XCTAssertEqual(
            NativServerErrorMessage.endpointFailure(
                endpoint: "Image endpoint",
                statusCode: 500,
                responseBody: "backend unavailable"
            ),
            "Image endpoint returned HTTP 500: backend unavailable"
        )
    }

    func testModelLoadFailureIsExtractedFromServerLogs() {
        let output = """
            INFO: Waiting for application startup.
            ERROR loading model mlx-community/BERT: Model type bert not supported.
            ERROR: Application startup failed.
            """

        XCTAssertEqual(
            NativServerErrorMessage.modelLoadFailure(in: output),
            "Failed to load model: Model type bert not supported."
        )
        XCTAssertNil(
            NativServerErrorMessage.modelLoadFailure(
                in: "Chat endpoint returned HTTP 400: Prompt is too long."
            )
        )
    }

    func testPortConflictFailureIsDetectedFromServerLogs() {
        let output = """
            INFO:     Application startup complete.
            ERROR:    [Errno 48] error while attempting to bind on address ('127.0.0.1', 8080): [errno 48] address already in use
            INFO:     Waiting for application shutdown.
            """

        XCTAssertTrue(NativServerErrorMessage.isPortConflictFailure(in: output))
        XCTAssertFalse(
            NativServerErrorMessage.isPortConflictFailure(
                in: "ERROR: Application startup failed."
            )
        )
    }
}

extension Array where Element == String {
    fileprivate func containsAdjacent(_ first: String, _ second: String) -> Bool {
        indices.dropLast().contains {
            self[$0] == first && self[index(after: $0)] == second
        }
    }
}

final class ServerPortProbeTests: XCTestCase {
    func testProbeDetectsActiveListener() throws {
        let listener = try makeLoopbackListener()
        defer { close(listener.descriptor) }

        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: listener.port),
            .addressInUse
        )
    }

    func testProbeAllowsImmediateReuseAfterServerClosesConnection() throws {
        let listener = try makeLoopbackListener()
        let client = try connectToLoopback(port: listener.port)
        let accepted = accept(listener.descriptor, nil, nil)
        guard accepted >= 0 else {
            close(client)
            close(listener.descriptor)
            throw SocketTestError.operation("accept", errno)
        }

        close(listener.descriptor)
        close(accepted)
        var byte: UInt8 = 0
        _ = recv(client, &byte, 1, 0)
        close(client)

        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: listener.port),
            .available
        )
    }

    private func makeLoopbackListener() throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketTestError.operation("socket", errno)
        }

        var reuseAddress: Int32 = 1
        guard
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout.size(ofValue: reuseAddress))
            ) == 0
        else {
            let error = errno
            close(descriptor)
            throw SocketTestError.operation("setsockopt", error)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            let error = errno
            close(descriptor)
            throw SocketTestError.operation("bind/listen", error)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            let error = errno
            close(descriptor)
            throw SocketTestError.operation("getsockname", error)
        }

        return (
            descriptor,
            Int(UInt16(bigEndian: boundAddress.sin_port))
        )
    }

    private func connectToLoopback(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketTestError.operation("socket", errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            let error = errno
            close(descriptor)
            throw SocketTestError.operation("connect", error)
        }
        return descriptor
    }
}

@MainActor
final class ChatTimeoutTests: XCTestCase {
    func testPreferencesMigrateAndRoundTripWithoutChangingServerArguments() throws {
        for json in ["{}", "{\"chatResponseTimeout\":123}"] {
            let settings = try JSONDecoder().decode(NativSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.chatResponseTimeout, .tenMinutes)
        }
        let defaults = NativSettings()
        for timeout in NativChatTimeout.allCases {
            var settings = defaults
            settings.chatResponseTimeout = timeout
            let decoded = try PropertyListDecoder().decode(
                NativSettings.self, from: PropertyListEncoder().encode(settings)
            ).normalized()
            XCTAssertEqual(decoded.chatResponseTimeout, timeout)
            XCTAssertEqual(decoded.launchArguments, defaults.normalized().launchArguments)
            if timeout == .unlimited {
                XCTAssertEqual(timeout.resourceTimeout, .greatestFiniteMagnitude)
            } else {
                XCTAssertGreaterThan(timeout.resourceTimeout, timeout.idleTimeout)
            }
        }
    }

    func testSelectedTimeoutReachesBothWireRequests() throws {
        let url = URL(string: "http://127.0.0.1:8080")!
        for timeout in NativChatTimeout.allCases {
            let responses = NativResponsesClient(
                baseURL: url, tenant: "test", idleTimeout: timeout.idleTimeout,
                resourceTimeout: timeout.resourceTimeout
            )
            let chat = NativChatClient(
                baseURL: url, idleTimeout: timeout.idleTimeout, resourceTimeout: timeout.resourceTimeout
            )
            XCTAssertEqual(try responses.makeResponseRequest(request, input: [], compactThreshold: 1000).timeoutInterval, timeout.idleTimeout)
            XCTAssertEqual(try chat.makeURLRequest(payload: request, accepts: "text/event-stream").timeoutInterval, timeout.idleTimeout)
            XCTAssertEqual(try chat.makePromptTokenCountURLRequest(for: request).timeoutInterval, 10)
        }
    }

    func testLongerIdleWaitAllowsSilentPrefillOnBothTransports() async throws {
        let server = try ChatTimeoutHTTPFixture(delays: [2])
        let url = try await server.start()
        defer { server.stop() }
        for responses in [true, false] {
            do {
                _ = try await completion(url: url, responses: responses, idle: 1, resource: 10)
                XCTFail("A silent prefill should exceed the short idle timeout")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .timedOut)
            }
            let result = try await completion(url: url, responses: responses, idle: 4, resource: 10)
            XCTAssertEqual(result.content, "Done")
        }
    }

    func testIncomingDataResetsIdleWaitAndResourceCapIsSeparate() async throws {
        let server = try ChatTimeoutHTTPFixture(delays: [0.6, 1.2, 1.8, 2.4])
        let url = try await server.start()
        defer { server.stop() }
        for responses in [true, false] {
            let result = try await completion(url: url, responses: responses, idle: 1.5, resource: 5)
            XCTAssertEqual(result.content, "Done")
            do {
                _ = try await completion(url: url, responses: responses, idle: 4, resource: 1)
                XCTFail("The overall resource cap should still be enforced")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .timedOut)
            }
        }
    }

    func testUnlimitedRequestsCanCompleteAndBeCancelled() async throws {
        let server = try ChatTimeoutHTTPFixture(delays: [2])
        let url = try await server.start()
        defer { server.stop() }
        let unlimited = NativChatTimeout.unlimited
        for responses in [true, false] {
            let result = try await completion(
                url: url, responses: responses, idle: unlimited.idleTimeout, resource: unlimited.resourceTimeout
            )
            XCTAssertEqual(result.content, "Done")
            let task = Task {
                try await completion(
                    url: url, responses: responses, idle: unlimited.idleTimeout, resource: unlimited.resourceTimeout
                )
            }
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("An unlimited request must remain cancellable")
            } catch is CancellationError {
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            }
        }
    }

    private var request: MLXChatCompletionRequest {
        .init(model: "test", messages: [.init(role: "user", content: "Hello")],
              maxTokens: 16, temperature: 0, topK: 0, topP: 1, minP: 0)
    }

    private func completion(url: URL, responses: Bool, idle: TimeInterval, resource: TimeInterval) async throws -> MLXChatCompletion {
        if responses {
            return try await NativResponsesClient(
                baseURL: url, tenant: "test", idleTimeout: idle, resourceTimeout: resource
            ).streamResponse(request, input: [], compactThreshold: 1000, onEvent: { _ in }).completion
        }
        return try await NativChatClient(
            baseURL: url, idleTimeout: idle, resourceTimeout: resource
        ).streamChat(request, onEvent: { _ in })
    }
}

@MainActor
private final class ChatTimeoutHTTPFixture {
    private let listener: NWListener

    init(delays: [TimeInterval]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.receive(connection, buffered: Data(), delays: delays)
        }
    }

    func start() async throws -> URL {
        listener.start(queue: .global())
        for _ in 0..<500 {
            if case .ready = listener.state, let port = listener.port {
                return URL(string: "http://127.0.0.1:\(port.rawValue)")!
            }
            if case .failed(let error) = listener.state { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    func stop() { listener.cancel() }

    nonisolated private static func receive(_ connection: NWConnection, buffered: Data, delays: [TimeInterval]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            let request = buffered + (data ?? Data())
            guard let headerRange = request.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() }
                else { receive(connection, buffered: request, delays: delays) }
                return
            }
            let headers = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
            let length = headers.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request.count >= headerRange.upperBound + length else {
                if complete || error != nil { connection.cancel() }
                else { receive(connection, buffered: request, delays: delays) }
                return
            }
            let responses = headers.hasPrefix("POST /v1/responses ")
            let body = responses
                ? "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done\"}]}]}}\n\n"
                : "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            for (index, delay) in delays.enumerated() {
                let last = index == delays.count - 1
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    connection.send(content: Data((last ? body : ": keep-alive\n\n").utf8), completion: .contentProcessed { _ in
                        if last { connection.cancel() }
                    })
                }
            }
        }
    }
}

private enum SocketTestError: Error {
    case operation(String, Int32)
}
