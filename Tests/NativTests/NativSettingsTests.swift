import XCTest
@testable import NativServerKit

final class NativSettingsTests: XCTestCase {
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
        XCTAssertEqual(settings.serverBaseURL.absoluteString, "http://0.0.0.0:9001")
        XCTAssertTrue(settings.launchArguments.containsAdjacent("--host", "0.0.0.0"))
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

    func testChatClientAddsServerAuthorization() throws {
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

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer nativ_chat_token"
        )
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
        XCTAssertFalse(settings.sidebarFoldersCollapsed)
        XCTAssertFalse(settings.sidebarSessionsCollapsed)
        XCTAssertFalse(settings.allSidebarSectionsCollapsed)

        settings.sidebarPinnedCollapsed = true
        settings.sidebarSessionsCollapsed = true
        let decoded = try JSONDecoder().decode(
            NativSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(decoded.sidebarPinnedCollapsed)
        XCTAssertFalse(decoded.sidebarFoldersCollapsed)
        XCTAssertTrue(decoded.sidebarSessionsCollapsed)
        XCTAssertFalse(decoded.allSidebarSectionsCollapsed)
    }

    func testSetAllSidebarSectionsCollapsedTogglesEveryFlag() {
        var settings = NativSettings()
        settings.setAllSidebarSectionsCollapsed(true)
        XCTAssertTrue(settings.sidebarPinnedCollapsed)
        XCTAssertTrue(settings.sidebarFoldersCollapsed)
        XCTAssertTrue(settings.sidebarSessionsCollapsed)
        XCTAssertTrue(settings.allSidebarSectionsCollapsed)

        settings.setAllSidebarSectionsCollapsed(false)
        XCTAssertFalse(settings.sidebarPinnedCollapsed)
        XCTAssertFalse(settings.sidebarFoldersCollapsed)
        XCTAssertFalse(settings.sidebarSessionsCollapsed)
        XCTAssertFalse(settings.allSidebarSectionsCollapsed)
    }

    func testSidebarSectionCollapseDefaultsToExpandedForExistingInstalls() throws {
        let legacyJSON = Data(#"{"serverHost":"127.0.0.1","serverPort":8080}"#.utf8)
        let decoded = try JSONDecoder().decode(NativSettings.self, from: legacyJSON)
        XCTAssertFalse(decoded.sidebarPinnedCollapsed)
        XCTAssertFalse(decoded.sidebarFoldersCollapsed)
        XCTAssertFalse(decoded.sidebarSessionsCollapsed)
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

    private func writeLegacySettings(serverAPIKey: String, to url: URL) throws {
        let encoded = try PropertyListEncoder().encode(NativSettings())
        var propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: encoded,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        propertyList["serverAPIKey"] = serverAPIKey
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

private final class TestServerAPICredentialStore: ServerAPICredentialStoring {
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
        let tool = MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: "generate_image",
            description: "Generate an image",
            parameters: .object([
                "type": .string("object"),
                "required": .array([.string("prompt")])
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
            )
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
        XCTAssertTrue(message.toolCalls?.first?.function?.arguments?.contains("A lighthouse") == true)
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
}

extension Array where Element == String {
    fileprivate func containsAdjacent(_ first: String, _ second: String) -> Bool {
        indices.dropLast().contains {
            self[$0] == first && self[index(after: $0)] == second
        }
    }
}
