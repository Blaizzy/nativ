import XCTest
@testable import NativServerKit

private let nativeToolNames = [
    ChatSystemMonitorToolRegistry.toolName,
    ChatModelLibraryToolRegistry.toolName,
    ChatServerStatsToolRegistry.toolName,
    ChatSwitchModelToolRegistry.toolName,
]

private struct FakeToolError: Error, LocalizedError {
    var errorDescription: String? { "fake failure" }
}

private actor ImageToolExecutionRecorder {
    private var modelID: String?

    func record(modelID: String) {
        self.modelID = modelID
    }

    func recordedModelID() -> String? {
        modelID
    }
}

@MainActor
private final class FakeModelSwitchingSurface: ChatModelSwitchingSurface {
    var settings: NativSettings
    var isRunning: Bool
    var modelSwitchInProgress = false
    private(set) var switchCallCount = 0
    var onSwitch: ((String?) -> Void)?

    init(languageModelID: String?, isRunning: Bool = true) {
        settings = NativSettings(languageModelID: languageModelID)
        self.isRunning = isRunning
    }

    func switchLanguageModel(to modelID: String?) {
        switchCallCount += 1
        if let onSwitch {
            onSwitch(modelID)
        } else {
            settings.languageModelID = modelID
        }
    }
}

private func makeContext(
    imageModelID: String? = nil,
    modelSearchPath: String = ""
) -> ChatToolExecutionContext {
    ChatToolExecutionContext(
        imageGenerationModelID: imageModelID,
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        apiKey: nil,
        imageReferences: [],
        modelSearchPath: modelSearchPath,
        additionalModelSearchPaths: [],
        analyticsDatabaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Analytics.sqlite3")
    )
}

private func makeCall(name: String, arguments: String = "{}") -> MLXChatToolCall {
    MLXChatToolCall(id: "1", function: MLXChatFunctionCall(name: name, arguments: arguments))
}

final class ChatToolRegistryTests: XCTestCase {
    func testDefinitionsAlwaysAdvertiseWebSearch() {
        let names = ChatToolRegistry.definitions(canEditImage: false)
            .map(\.function.name)

        XCTAssertTrue(names.contains(ChatWebSearchToolRegistry.toolName))
    }

    func testWebSearchCarriesConfigurationMetadata() {
        let descriptor = ChatToolRegistry.descriptors(canEditImage: false).first {
            $0.definition.function.name == ChatWebSearchToolRegistry.toolName
        }

        XCTAssertEqual(descriptor?.configuration, .webSearch)
        XCTAssertEqual(descriptor?.configuration?.displayName, "Web Search")
    }

    func testDefinitionsAdvertiseGenerationAndGuidanceWithNoImageModelConfigured() {
        let names = ChatToolRegistry.definitions(canEditImage: false)
            .map(\.function.name)

        XCTAssertTrue(names.contains(ChatImageToolRegistry.generateToolName))
        XCTAssertFalse(names.contains(ChatImageToolRegistry.editToolName))
        for toolName in nativeToolNames {
            XCTAssertTrue(names.contains(toolName), "\(toolName) should be advertised without an image model")
        }
    }

    func testDefinitionsOfferEditOnlyWhenAnImageIsAvailable() {
        let withoutEdit = ChatToolRegistry.definitions(canEditImage: false)
            .map(\.function.name)
        XCTAssertTrue(withoutEdit.contains(ChatImageToolRegistry.generateToolName))
        XCTAssertFalse(withoutEdit.contains(ChatImageToolRegistry.editToolName))

        let withEdit = ChatToolRegistry.definitions(canEditImage: true)
            .map(\.function.name)
        XCTAssertTrue(withEdit.contains(ChatImageToolRegistry.editToolName))
    }

    func testDefinitionsNeverAdvertiseDuplicateToolNames() {
        let names = ChatToolRegistry.definitions(canEditImage: true)
            .map(\.function.name)

        XCTAssertEqual(names.count, Set(names).count)
    }

    func testImageToolSchemasAreGoldenPinned() throws {
        let golden = #"""
            [{"function":{"description":"Create one or more new images from a detailed text prompt. Image-model selection is handled by the app; do not ask for or provide a model identifier.","name":"generate_image","parameters":{"additionalProperties":false,"properties":{"count":{"maximum":4,"minimum":1,"type":"integer"},"height":{"maximum":2048,"minimum":256,"type":"integer"},"prompt":{"description":"A specific visual description or edit instruction.","type":"string"},"seed":{"type":["integer","null"]},"width":{"maximum":2048,"minimum":256,"type":"integer"}},"required":["prompt"],"type":"object"}},"type":"function"},{"function":{"description":"Edit the most recently attached or generated image using a text instruction. Image-model selection is handled by the app; do not ask for or provide a model identifier.","name":"edit_image","parameters":{"additionalProperties":false,"properties":{"count":{"maximum":4,"minimum":1,"type":"integer"},"height":{"maximum":2048,"minimum":256,"type":"integer"},"prompt":{"description":"A specific visual description or edit instruction.","type":"string"},"seed":{"type":["integer","null"]},"width":{"maximum":2048,"minimum":256,"type":"integer"}},"required":["prompt"],"type":"object"}},"type":"function"}]
            """#

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ChatImageToolRegistry.definitions(canEdit: true))
        let actual = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(actual, golden, "generate_image/edit_image's schema must match the intended schema exactly -- if this fails, either the schema drifted unintentionally or this pin needs updating alongside a deliberate schema change")
    }

    func testImageToolKeepsModelSelectionOutOfTheLLMProtocol() throws {
        let definition = try XCTUnwrap(
            ChatImageToolRegistry.definitions(canEdit: false).first
        )
        XCTAssertTrue(definition.function.description.contains("handled by the app"))
        XCTAssertFalse(definition.function.description.contains("model_id"))
        XCTAssertFalse(definition.function.description.contains("list_image_models"))
    }

    func testPreselectedCompatibleImageModelResolvesExactly() {
        let resolution = ChatImageModelSelection.resolve(
            operation: .generate,
            selectedModelID: "org/generator",
            availableModels: imageModelOptions
        )

        guard case .selected(let model) = resolution else {
            return XCTFail("expected the app-owned selection to resolve")
        }
        XCTAssertEqual(model.modelID, "org/generator")
    }

    func testMissingSelectionReturnsOnlyGenerationModelsToTheApp() {
        let resolution = ChatImageModelSelection.resolve(
            operation: .generate,
            selectedModelID: nil,
            availableModels: imageModelOptions
        )

        guard case .selectionRequired(let request) = resolution else {
            return XCTFail("expected native model selection")
        }
        XCTAssertEqual(request.operation, .generate)
        XCTAssertEqual(request.models.map(\.modelID), ["org/generator", "org/both"])
    }

    func testSingleCompatibleModelStillRequiresExplicitSelection() {
        let onlyModel = ChatImageModelOption(
            displayName: "only-image-model",
            modelID: "org/only-image-model",
            capabilities: [.imageGeneration]
        )

        let resolution = ChatImageModelSelection.resolve(
            operation: .generate,
            selectedModelID: nil,
            availableModels: [onlyModel]
        )

        guard case .selectionRequired(let request) = resolution else {
            return XCTFail("the app must not auto-select the only compatible model")
        }
        XCTAssertEqual(request.models, [onlyModel])
    }

    func testLLMSuppliedModelIDHasNoPlaceInTheImageRequest() throws {
        let request = try ChatImageToolRequest(
            call: makeCall(
                name: "generate_image",
                arguments: #"{"prompt":"A lake","model_id":"org/untrusted"}"#
            ),
            hasImageReference: false
        )

        XCTAssertEqual(request.operation, .generate)
        XCTAssertEqual(request.prompt, "A lake")
    }

    func testStaleSelectionFallsBackToNativePicker() {
        let resolution = ChatImageModelSelection.resolve(
            operation: .generate,
            selectedModelID: "org/not-installed",
            availableModels: imageModelOptions
        )

        guard case .selectionRequired(let request) = resolution else {
            return XCTFail("a stale setting must recover through native selection")
        }
        XCTAssertEqual(request.models.map(\.modelID), ["org/generator", "org/both"])
    }

    func testImageEditSelectionReturnsOnlyEditingModelsToTheApp() {
        let resolution = ChatImageModelSelection.resolve(
            operation: .edit,
            selectedModelID: "org/generator",
            availableModels: imageModelOptions
        )

        guard case .selectionRequired(let request) = resolution else {
            return XCTFail("an incompatible saved model must trigger native selection")
        }
        XCTAssertEqual(request.models.map(\.modelID), ["org/editor", "org/both"])
    }

    func testNoInstalledImageModelStillPresentsExploreFlow() {
        let resolution = ChatImageModelSelection.resolve(
            operation: .generate,
            selectedModelID: nil,
            availableModels: []
        )

        guard case .selectionRequired(let request) = resolution else {
            return XCTFail("an empty picker must remain available for model discovery")
        }
        XCTAssertEqual(request.operation, .generate)
        XCTAssertTrue(request.models.isEmpty)
    }

    func testPickerShowsAllDownloadedModelsAndThreeHubRecommendations() {
        let installed = [
            imageModelOption("org/local-b"),
            imageModelOption("org/local-a"),
        ]
        let downloadable = (1...5).map {
            imageModelOption(
                "org/remote-\($0)",
                availability: .downloadable(sizeBytes: Int64($0) * 1_000)
            )
        }

        let options = ChatImageModelSelection.displayOptions(
            for: .generate,
            installedModels: installed,
            downloadableModels: downloadable
        )

        XCTAssertEqual(options.count, 5)
        XCTAssertEqual(Array(options.prefix(2).map(\.modelID)), ["org/local-a", "org/local-b"])
        XCTAssertEqual(options.filter { !$0.isInstalled }.count, 3)
    }

    func testPickerAlwaysShowsEveryDownloadedModel() {
        let installed = (1...7).map { imageModelOption("org/local-\($0)") }
        let downloadable = (1...5).map {
            imageModelOption(
                "org/remote-\($0)",
                availability: .downloadable(sizeBytes: Int64($0) * 1_000)
            )
        }

        let options = ChatImageModelSelection.displayOptions(
            for: .generate,
            installedModels: installed,
            downloadableModels: downloadable
        )

        XCTAssertEqual(options.count, 10)
        XCTAssertEqual(options.filter(\.isInstalled).count, 7)
        XCTAssertEqual(options.filter { !$0.isInstalled }.count, 3)
    }

    func testOfflinePickerShowsOnlyDownloadedModels() {
        let installed = [imageModelOption("org/local")]

        let options = ChatImageModelSelection.displayOptions(
            for: .generate,
            installedModels: installed,
            downloadableModels: []
        )

        XCTAssertEqual(options, installed)
    }

    func testOfflineRecommendationFailureReturnsAnEmptyPicker() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let options = try await ChatImageModelSelection.availableOptions(
            for: .generate,
            modelSearchPath: missingPath,
            additionalModelSearchPaths: [],
            huggingFaceToken: nil,
            recommendationLoader: { _, _ in
                throw URLError(.notConnectedToInternet)
            }
        )

        XCTAssertTrue(options.isEmpty)
    }

    func testRecommendationsOnlyAcceptSupportedMLXImageFamilies() {
        XCTAssertEqual(
            ChatImageModelSelection.downloadableCapabilities(
                modelID: "mlx-community/flux2-klein-4b-8bit",
                tags: ["mlx"]
            ),
            [.imageGeneration, .imageEditing]
        )
        XCTAssertEqual(
            ChatImageModelSelection.downloadableCapabilities(
                modelID: "mlx-community/stable-diffusion-xl",
                tags: ["mlx"]
            ),
            []
        )
        XCTAssertEqual(
            ChatImageModelSelection.downloadableCapabilities(
                modelID: "MLXBits/ideogram-4-mlx-q4",
                tags: ["gguf"]
            ),
            []
        )
    }

    func testDownloadedModelIsValidatedBeforeToolExecution() {
        let model = imageModelOption("org/generator")

        XCTAssertTrue(ChatImageModelSelection.isPrepared(
            modelID: model.modelID,
            for: .generate,
            installedModels: [model]
        ))
        XCTAssertFalse(ChatImageModelSelection.isPrepared(
            modelID: model.modelID,
            for: .edit,
            installedModels: [model]
        ))
    }

    func testExploreModelsUsesTheRequestedImageCapability() {
        XCTAssertEqual(ChatImageOperation.generate.requiredCapability, .imageGeneration)
        XCTAssertEqual(ChatImageOperation.edit.requiredCapability, .imageEditing)
    }

    func testPickerDoesNotRecommendAnAlreadyDownloadedModel() {
        let installed = [imageModelOption("org/shared")]
        let downloadable = [
            imageModelOption(
                "org/shared",
                availability: .downloadable(sizeBytes: nil)
            ),
            imageModelOption(
                "org/remote",
                availability: .downloadable(sizeBytes: nil)
            ),
        ]

        let options = ChatImageModelSelection.displayOptions(
            for: .generate,
            installedModels: installed,
            downloadableModels: downloadable
        )

        XCTAssertEqual(options.map(\.modelID), ["org/shared", "org/remote"])
    }

    func testSavedDownloadableModelStillRequiresUserSelection() {
        let downloadable = imageModelOption(
            "org/remote",
            availability: .downloadable(sizeBytes: nil)
        )

        let resolution = ChatImageModelSelection.resolve(
            operation: .generate,
            selectedModelID: downloadable.modelID,
            availableModels: [downloadable]
        )

        guard case .selectionRequired(let request) = resolution else {
            return XCTFail("a remote recommendation must not download without consent")
        }
        XCTAssertEqual(request.models, [downloadable])
    }

    func testPreselectedDownloadedModelSkipsHubRecommendations() {
        let installed = [imageModelOption("org/local")]

        XCTAssertFalse(ChatImageModelSelection.needsRecommendations(
            preferredInstalledModelID: "org/local",
            installedModels: installed
        ))
        XCTAssertTrue(ChatImageModelSelection.needsRecommendations(
            preferredInstalledModelID: "org/missing",
            installedModels: installed
        ))
    }

    func testNativeSelectionRejectsAnIdentifierOutsideItsRequest() throws {
        let request = ChatImageModelSelectionRequest(
            operation: .generate,
            models: imageModelOptions.filter { $0.supports(.generate) }
        )

        XCTAssertNil(ChatImageModelSelection.selectedModel(
            withID: "org/language-model",
            from: request
        ))
        XCTAssertEqual(
            ChatImageModelSelection.selectedModel(
                withID: "org/both",
                from: request
            )?.modelID,
            "org/both"
        )
    }

    func testInstallationFailurePayloadDoesNotExposeModelChoices() throws {
        let object = try decode(ChatImageToolExecutor().failurePayload(
            operation: ChatImageToolRegistry.generateToolName,
            error: ChatImageToolError.noCompatibleModels(.generate)
        ))

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["installation_required"] as? Bool, true)
        XCTAssertNil(object["models"])
        XCTAssertNil(object["model_id"])
    }

    @MainActor
    func testMissingModelCacheDoesNotStartImageGeneration() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        var didStartExecution = false
        var imageContext = makeContext(modelSearchPath: missingPath)
        imageContext.imageToolDependencies = ChatImageToolDependencies(
            discoverModels: { _, path, additionalPaths, _, _ in
                try await ChatImageModelSelection.installedOptions(
                    modelSearchPath: path,
                    additionalModelSearchPaths: additionalPaths
                )
            },
            execute: { _, _, _, _, _ in
                throw FakeToolError()
            }
        )
        imageContext.imageExecutionWillStart = { _ in
            didStartExecution = true
        }
        do {
            _ = try await ChatToolDispatcher.execute(
                call: makeCall(
                    name: ChatImageToolRegistry.generateToolName,
                    arguments: #"{"prompt":"A lake"}"#
                ),
                context: imageContext
            )
            XCTFail("generation must not start when the model cache is missing")
        } catch let error as ChatImageToolError {
            guard case .noCompatibleModels(.generate) = error else {
                return XCTFail("expected noCompatibleModels(.generate), got \(error)")
            }
        } catch {
            XCTFail("expected ChatImageToolError, got \(error)")
        }
        XCTAssertFalse(didStartExecution)
    }

    @MainActor
    func testNativeSelectionPropagatesExactModelIDToExecutionAndSessionCallback() async throws {
        let selectedModel = ChatImageModelOption(
            displayName: "Image Model",
            modelID: "org/image-model",
            capabilities: [.imageGeneration]
        )
        let languageModel = ChatImageModelOption(
            displayName: "Language Model",
            modelID: "org/language-model",
            capabilities: [.text, .tools]
        )
        let recorder = ImageToolExecutionRecorder()
        var sessionModelID: String?
        var context = makeContext()
        context.imageToolDependencies = ChatImageToolDependencies(
            discoverModels: { _, _, _, _, _ in [selectedModel, languageModel] },
            execute: { _, modelID, _, _, _ in
                await recorder.record(modelID: modelID)
                return ChatImageToolExecution(content: #"{"ok":true}"#, attachments: [])
            }
        )
        context.imageModelSelection = { request in
            XCTAssertEqual(request.models, [selectedModel])
            return selectedModel.modelID
        }
        context.imageExecutionWillStart = { modelID in
            sessionModelID = modelID
        }

        _ = try await ChatToolDispatcher.execute(
            call: makeCall(
                name: ChatImageToolRegistry.generateToolName,
                arguments: #"{"prompt":"A lake"}"#
            ),
            context: context
        )

        let executedModelID = await recorder.recordedModelID()
        XCTAssertEqual(sessionModelID, selectedModel.modelID)
        XCTAssertEqual(executedModelID, selectedModel.modelID)
    }

    func testDispatchRoutesToRegisteredHandler() async throws {
        let outcome = try await ChatToolDispatcher.execute(
            call: makeCall(name: ChatServerStatsToolRegistry.toolName),
            context: makeContext()
        )

        let data = try XCTUnwrap(outcome.content.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertNotNil(object["requests_completed"])
    }

    func testDispatchingUnknownToolThrows() async {
        do {
            _ = try await ChatToolDispatcher.execute(call: makeCall(name: "not_a_real_tool"), context: makeContext())
            XCTFail("dispatching an unregistered tool name must throw")
        } catch {}
    }

    func testRoundGateAdvertisesToolsUnderTheCapAndStopsAtIt() {
        XCTAssertEqual(ChatToolRoundGate.maximumRounds, 4)
        for round in 0..<ChatToolRoundGate.maximumRounds {
            XCTAssertTrue(ChatToolRoundGate.advertisesTools(atRound: round), "round \(round) should still advertise tools")
        }
        XCTAssertFalse(ChatToolRoundGate.advertisesTools(atRound: ChatToolRoundGate.maximumRounds))
        XCTAssertFalse(ChatToolRoundGate.advertisesTools(atRound: ChatToolRoundGate.maximumRounds + 3))
    }

    func testSwitchModelIsUnreachableThroughGenericDispatcherExecute() async {
        do {
            _ = try await ChatToolDispatcher.execute(
                call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: #"{"model_id":"org/model"}"#),
                context: makeContext()
            )
            XCTFail("switch_model must never execute through the generic dispatcher without the consent gate")
        } catch {}
    }

    func testConsentRouterTreatsCancellationAsHigherPriorityThanApproval() {
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: true, isCancelled: true), .cancelled)
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: false, isCancelled: true), .cancelled)
    }

    func testConsentRouterFallsBackToApprovalWhenNotCancelled() {
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: true, isCancelled: false), .approved)
        XCTAssertEqual(ChatToolConsentRouter.outcome(approved: false, isCancelled: false), .declined)
    }

    func testFailurePayloadCoveredForEveryNativeToolExecuteHandles() throws {
        for toolName in nativeToolNames {
            let payload = ChatToolDispatcher.failurePayload(toolName: toolName, error: FakeToolError())
            let data = try XCTUnwrap(payload.data(using: .utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["ok"] as? Bool, false, "\(toolName) failurePayload should report ok:false")
            XCTAssertNil(object["operation"], "\(toolName) failurePayload should not fall through to the image-tool shape (which always encodes a non-optional \"operation\" field)")
        }
    }

    func testSystemMonitorFailurePayloadShape() throws {
        let payload = ChatSystemMonitorToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
        XCTAssertNil(object["cpu_usage_percent"])
    }

    func testModelLibraryFailurePayloadShape() throws {
        let payload = ChatModelLibraryToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
        XCTAssertNil(object["models"])
    }

    func testServerStatsFailurePayloadShape() throws {
        let payload = ChatServerStatsToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
        XCTAssertNil(object["requests_completed"])
    }

    func testSwitchModelFailurePayloadShape() throws {
        let payload = ChatSwitchModelToolExecutor().failurePayload(operation: "x", error: FakeToolError())
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["declined"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "fake failure")
    }

    func testSwitchModelDeclinedPayloadShape() throws {
        let payload = ChatSwitchModelToolExecutor().declinedPayload()
        let object = try decode(payload)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["declined"] as? Bool, true)
        XCTAssertNotNil(object["error"])
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var imageModelOptions: [ChatImageModelOption] {
        [
            ChatImageModelOption(
                displayName: "generator",
                modelID: "org/generator",
                capabilities: [.imageGeneration]
            ),
            ChatImageModelOption(
                displayName: "editor",
                modelID: "org/editor",
                capabilities: [.imageEditing]
            ),
            ChatImageModelOption(
                displayName: "both",
                modelID: "org/both",
                capabilities: [.imageGeneration, .imageEditing]
            ),
            ChatImageModelOption(
                displayName: "language-model",
                modelID: "org/language-model",
                capabilities: [.text, .tools]
            ),
        ]
    }

    private func imageModelOption(
        _ modelID: String,
        availability: ChatImageModelOption.Availability = .installed
    ) -> ChatImageModelOption {
        ChatImageModelOption(
            displayName: modelID.split(separator: "/").last.map(String.init) ?? modelID,
            modelID: modelID,
            capabilities: [.imageGeneration],
            availability: availability
        )
    }
}

@MainActor
final class ChatToolConsentGateTests: XCTestCase {
    func testConfirmResolvesAwaitingDecisionTrue() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        async let result = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.confirm(id)

        let decision = await result
        XCTAssertTrue(decision)
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testDenyResolvesAwaitingDecisionFalse() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        async let result = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.deny(id)

        let decision = await result
        XCTAssertFalse(decision)
    }

    func testCancellingTheWaitingTaskResolvesFalse() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        let task = Task<Bool, Never> {
            await gate.awaitDecision(for: id)
        }
        await waitUntilPending(gate, count: 1)
        task.cancel()

        let decision = await task.value
        XCTAssertFalse(decision, "a cancelled wait must resolve false, not hang or resolve true")
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testAwaitDecisionResolvesWhenTaskIsAlreadyCancelledBeforeItStarts() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        let task = Task<Bool, Never> {
            await gate.awaitDecision(for: id)
        }
        task.cancel()

        let decision = await task.value
        XCTAssertFalse(decision, "a task cancelled before awaitDecision ever runs must still resolve false, not hang forever")
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testDenyThenReaskAllowsAFreshConsentCycleForTheSameID() async {
        let gate = ChatToolConsentGate()
        let id = UUID()

        async let firstResult = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.deny(id)
        let first = await firstResult
        XCTAssertFalse(first)
        XCTAssertEqual(gate.pendingCount, 0)

        async let secondResult = gate.awaitDecision(for: id)
        await waitUntilPending(gate, count: 1)
        gate.confirm(id)
        let second = await secondResult
        XCTAssertTrue(second, "re-offering the same tool message id must start a fresh, independent wait")
    }

    func testConfirmAndDenyAreSafeNoOpsForAnUnregisteredID() {
        let gate = ChatToolConsentGate()
        gate.confirm(UUID())
        gate.deny(UUID())
        XCTAssertEqual(gate.pendingCount, 0)
    }

    private func waitUntilPending(_ gate: ChatToolConsentGate, count: Int) async {
        for _ in 0..<200 where gate.pendingCount < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
final class ChatImageModelSelectionGateTests: XCTestCase {
    func testSelectionResumesWithTheAppOwnedModelID() async {
        let gate = ChatImageModelSelectionGate()
        let requestID = UUID()

        async let result = gate.awaitSelection(for: requestID) {}
        await waitUntilPending(gate)

        gate.select(modelID: "org/image", for: requestID)
        let selectedModelID = await result
        XCTAssertEqual(selectedModelID, "org/image")
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testCancellingSelectionResumesWithNil() async {
        let gate = ChatImageModelSelectionGate()
        let requestID = UUID()

        async let result = gate.awaitSelection(for: requestID) {}
        await waitUntilPending(gate)
        gate.cancel(requestID)

        let selectedModelID = await result
        XCTAssertNil(selectedModelID)
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testCancellingWaitingTaskCannotLeaveASelectionPending() async {
        let gate = ChatImageModelSelectionGate()
        let requestID = UUID()
        let task = Task<String?, Never> {
            await gate.awaitSelection(for: requestID) {}
        }
        await waitUntilPending(gate)

        task.cancel()

        let selectedModelID = await task.value
        XCTAssertNil(selectedModelID)
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testAlreadyCancelledTaskCannotLeaveASelectionPending() async {
        let gate = ChatImageModelSelectionGate()
        let requestID = UUID()
        let task = Task<String?, Never> {
            await gate.awaitSelection(for: requestID) {}
        }
        task.cancel()

        let selectedModelID = await task.value
        XCTAssertNil(selectedModelID)
        XCTAssertEqual(gate.pendingCount, 0)
    }

    private func waitUntilPending(_ gate: ChatImageModelSelectionGate) async {
        for _ in 0..<200 where gate.pendingCount == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

final class ChatSessionLoadPolicyTests: XCTestCase {
    func testDoesNotNormalizeTheSessionWithTheActiveInFlightRequest() {
        let sessionID = UUID()
        XCTAssertFalse(
            ChatSessionLoadPolicy.shouldNormalizeOnApply(sessionID: sessionID, activeRequestSessionID: sessionID),
            "switching back into the session that owns the in-flight request must not rewrite its live awaitingConsent/running messages"
        )
    }

    func testNormalizesAnySessionThatIsNotTheActiveRequests() {
        XCTAssertTrue(
            ChatSessionLoadPolicy.shouldNormalizeOnApply(sessionID: UUID(), activeRequestSessionID: UUID())
        )
        XCTAssertTrue(
            ChatSessionLoadPolicy.shouldNormalizeOnApply(sessionID: UUID(), activeRequestSessionID: nil),
            "a genuine load with no active request at all must still normalize stale state"
        )
    }
}

final class ChatToolPresentationTests: XCTestCase {
    private static let allStatuses: [ChatTranscriptMessage.ToolStatus?] = [
        nil, .preparing, .awaitingImageModelSelection, .running, .succeeded,
        .failed, .cancelled, .awaitingConsent, .declined,
    ]

    func testTitlePinnedForEveryToolAndStatus() {
        let expected: [String: [ChatTranscriptMessage.ToolStatus?: String]] = [
            "generate_image": [
                nil: "Image tool", .preparing: "Checking image model…",
                .running: "Generating image…", .succeeded: "Generated image",
                .failed: "Image generation", .cancelled: "Image generation",
                .awaitingImageModelSelection: "Choose image model",
                .awaitingConsent: "Image generation", .declined: "Image generation",
            ],
            "edit_image": [
                nil: "Image tool", .preparing: "Checking image model…",
                .running: "Editing image…", .succeeded: "Edited image",
                .failed: "Image edit", .cancelled: "Image edit",
                .awaitingImageModelSelection: "Choose image model",
                .awaitingConsent: "Image edit", .declined: "Image edit",
            ],
            ChatSystemMonitorToolRegistry.toolName: [
                nil: "System tool", .preparing: "Checking system stats…",
                .running: "Checking system stats…", .succeeded: "Checked system stats",
                .failed: "System stats", .cancelled: "System stats",
                .awaitingImageModelSelection: "System stats",
                .awaitingConsent: "System stats", .declined: "System stats",
            ],
            ChatModelLibraryToolRegistry.toolName: [
                nil: "Model library tool", .preparing: "Listing downloaded models…",
                .running: "Listing downloaded models…", .succeeded: "Listed downloaded models",
                .failed: "Model library", .cancelled: "Model library",
                .awaitingImageModelSelection: "Model library",
                .awaitingConsent: "Model library", .declined: "Model library",
            ],
            ChatServerStatsToolRegistry.toolName: [
                nil: "Server stats tool", .preparing: "Checking server stats…",
                .running: "Checking server stats…", .succeeded: "Checked server stats",
                .failed: "Server stats", .cancelled: "Server stats",
                .awaitingImageModelSelection: "Server stats",
                .awaitingConsent: "Server stats", .declined: "Server stats",
            ],
            ChatSwitchModelToolRegistry.toolName: [
                nil: "Model switch tool", .preparing: "Switching model…",
                .running: "Switching model…", .succeeded: "Switched model",
                .failed: "Model switch", .cancelled: "Model switch",
                .awaitingImageModelSelection: "Model switch",
                .awaitingConsent: "Switch model?", .declined: "Model switch declined",
            ],
            "some_unknown_tool": [
                nil: "some_unknown_tool", .preparing: "Running some_unknown_tool…",
                .running: "Running some_unknown_tool…", .succeeded: "Ran some_unknown_tool",
                .failed: "some_unknown_tool", .cancelled: "some_unknown_tool",
                .awaitingImageModelSelection: "some_unknown_tool",
                .awaitingConsent: "some_unknown_tool", .declined: "some_unknown_tool",
            ],
        ]

        for (toolName, byStatus) in expected {
            for status in Self.allStatuses {
                XCTAssertEqual(
                    ChatToolPresentation.title(toolName: toolName, status: status),
                    byStatus[status],
                    "title mismatch for tool=\(toolName) status=\(String(describing: status))"
                )
            }
        }

        // toolName itself nil (no tool selected at all) falls through to the generic path.
        XCTAssertEqual(ChatToolPresentation.title(toolName: nil, status: nil), "tool")
        XCTAssertEqual(ChatToolPresentation.title(toolName: nil, status: .running), "Running tool…")
        XCTAssertEqual(ChatToolPresentation.title(toolName: nil, status: .succeeded), "Ran tool")
    }

    func testSymbolNamePinnedForEveryToolAndStatus() {
        let toolNames = [
            "generate_image", "edit_image",
            ChatSystemMonitorToolRegistry.toolName, ChatModelLibraryToolRegistry.toolName,
            ChatServerStatsToolRegistry.toolName, ChatSwitchModelToolRegistry.toolName,
            "some_unknown_tool",
        ]
        let successLikeSymbol: [String: String] = [
            "generate_image": "photo",
            "edit_image": "photo",
            ChatSystemMonitorToolRegistry.toolName: "cpu",
            ChatModelLibraryToolRegistry.toolName: "shippingbox",
            ChatServerStatsToolRegistry.toolName: "chart.line.uptrend.xyaxis",
            ChatSwitchModelToolRegistry.toolName: "arrow.triangle.2.circlepath",
            "some_unknown_tool": "wrench.and.screwdriver",
        ]

        for toolName in toolNames {
            // Status takes priority over tool identity for these three.
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .failed), "exclamationmark.triangle.fill")
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .cancelled), "xmark.circle")
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .declined), "xmark.circle")
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .awaitingConsent), "questionmark.circle")
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .awaitingImageModelSelection), "photo.badge.checkmark")
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .preparing), "magnifyingglass")

            // Only succeeded/running/nil fall through to the per-tool icon.
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .succeeded), successLikeSymbol[toolName])
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: .running), successLikeSymbol[toolName])
            XCTAssertEqual(ChatToolPresentation.symbolName(toolName: toolName, status: nil), successLikeSymbol[toolName])
        }
    }
}

@MainActor
final class ChatSwitchModelToolExecutorTests: XCTestCase {
    func testInvalidJSONArgumentsThrowsInvalidArguments() async {
        let fake = FakeModelSwitchingSurface(languageModelID: "org/current")
        do {
            _ = try await ChatSwitchModelToolExecutor().execute(
                call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: "not json"),
                appModel: fake
            )
            XCTFail("malformed JSON arguments must throw")
        } catch let error as ChatSwitchModelToolError {
            guard case .invalidArguments = error else {
                return XCTFail("expected .invalidArguments, got \(error)")
            }
        } catch {
            XCTFail("expected ChatSwitchModelToolError, got \(error)")
        }
        XCTAssertEqual(fake.switchCallCount, 0)
    }

    func testMissingModelIDThrowsInvalidArguments() async {
        let fake = FakeModelSwitchingSurface(languageModelID: "org/current")
        do {
            _ = try await ChatSwitchModelToolExecutor().execute(
                call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: "{}"),
                appModel: fake
            )
            XCTFail("missing required model_id must throw")
        } catch let error as ChatSwitchModelToolError {
            guard case .invalidArguments = error else {
                return XCTFail("expected .invalidArguments, got \(error)")
            }
        } catch {
            XCTFail("expected ChatSwitchModelToolError, got \(error)")
        }
        XCTAssertEqual(fake.switchCallCount, 0)
    }

    func testSameModelRequestNoOpsWithoutCallingSwitch() async throws {
        let fake = FakeModelSwitchingSurface(languageModelID: "org/current")
        let content = try await ChatSwitchModelToolExecutor().execute(
            call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: #"{"model_id":"org/current"}"#),
            appModel: fake
        )
        let object = try decode(content)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["changed"] as? Bool, false)
        XCTAssertEqual(fake.switchCallCount, 0, "a same-model request must not trigger a real switch/restart")
    }

    func testSuccessfulSwitchReportsChangedTrueWithBothModelIDs() async throws {
        let fake = FakeModelSwitchingSurface(languageModelID: "org/old")
        let content = try await ChatSwitchModelToolExecutor().execute(
            call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: #"{"model_id":"org/new"}"#),
            appModel: fake
        )
        let object = try decode(content)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["changed"] as? Bool, true)
        XCTAssertEqual(object["previous_model_id"] as? String, "org/old")
        XCTAssertEqual(object["new_model_id"] as? String, "org/new")
        XCTAssertEqual(fake.switchCallCount, 1)
    }

    func testServerNotRunningAfterSwitchThrowsSwitchFailed() async {
        let fake = FakeModelSwitchingSurface(languageModelID: "org/old")
        fake.onSwitch = { [weak fake] modelID in
            fake?.settings.languageModelID = modelID
            fake?.isRunning = false
        }
        do {
            _ = try await ChatSwitchModelToolExecutor().execute(
                call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: #"{"model_id":"org/new"}"#),
                appModel: fake
            )
            XCTFail("a server that isn't running after the switch must throw")
        } catch let error as ChatSwitchModelToolError {
            guard case .switchFailed = error else {
                return XCTFail("expected .switchFailed, got \(error)")
            }
        } catch {
            XCTFail("expected ChatSwitchModelToolError, got \(error)")
        }
    }

    func testActiveModelStillMismatchedAfterSwitchThrowsMismatchedModel() async {
        let fake = FakeModelSwitchingSurface(languageModelID: "org/old")
        // Simulate the server coming back up with a different model than requested.
        fake.onSwitch = { [weak fake] _ in
            fake?.settings.languageModelID = "org/unexpected"
        }
        do {
            _ = try await ChatSwitchModelToolExecutor().execute(
                call: makeCall(name: ChatSwitchModelToolRegistry.toolName, arguments: #"{"model_id":"org/new"}"#),
                appModel: fake
            )
            XCTFail("an active model that doesn't match the request must throw")
        } catch let error as ChatSwitchModelToolError {
            guard case .mismatchedModel(let requested, let active) = error else {
                return XCTFail("expected .mismatchedModel, got \(error)")
            }
            XCTAssertEqual(requested, "org/new")
            XCTAssertEqual(active, "org/unexpected")
        } catch {
            XCTFail("expected ChatSwitchModelToolError, got \(error)")
        }
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
final class ChatSystemMonitorToolExecutorTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testScalingWithGPUUsagePresent() async throws {
        var snapshot = SystemMonitorSnapshot()
        snapshot.cpu.totalUsage = 0.5
        snapshot.gpu.deviceUsage = 0.75
        snapshot.memory.usedBytes = 2 * gib
        snapshot.memory.totalBytes = 8 * gib
        snapshot.disk.totalBytes = 10 * gib
        snapshot.disk.availableBytes = 6 * gib
        snapshot.uptime = 100

        let content = try await ChatSystemMonitorToolExecutor().execute(
            call: makeCall(name: ChatSystemMonitorToolRegistry.toolName),
            collect: { snapshot }
        )
        let object = try decode(content)

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["cpu_usage_percent"] as? Int, 50, "0.5 usage must scale to 50, not 0.5")
        XCTAssertEqual(object["gpu_usage_percent"] as? Int, 75)
        XCTAssertEqual(object["memory_used_gb"] as? Double, 2.0)
        XCTAssertEqual(object["memory_total_gb"] as? Double, 8.0)
        XCTAssertEqual(object["disk_used_gb"] as? Double, 4.0, "disk usedBytes is computed as total - available (10 - 6 GiB)")
        XCTAssertEqual(object["disk_total_gb"] as? Double, 10.0)
        XCTAssertEqual(object["uptime_seconds"] as? Int, 100)
    }

    func testGPUUsageOmittedWhenDeviceHasNoGPUReading() async throws {
        var snapshot = SystemMonitorSnapshot()
        snapshot.gpu.deviceUsage = nil

        let content = try await ChatSystemMonitorToolExecutor().execute(
            call: makeCall(name: ChatSystemMonitorToolRegistry.toolName),
            collect: { snapshot }
        )
        let object = try decode(content)

        XCTAssertNil(object["gpu_usage_percent"], "no GPU reading must omit the field, not report 0")
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class ChatTranscriptMessageCodableTests: XCTestCase {
    func testChatSessionPersistsSelectedImageModelID() throws {
        let session = ChatSession(
            id: UUID(),
            title: "Images",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            messages: [],
            imageGenerationModelID: "org/image"
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

        XCTAssertEqual(decoded.imageGenerationModelID, "org/image")
    }

    func testOldChatSessionWithoutImageModelSelectionStillDecodes() throws {
        let oldJSON = #"{"id":"8A6D9E1B-2C1B-4A9E-9C1B-2C1B4A9E9C1B","title":"Old","createdAt":0,"updatedAt":0,"messages":[]}"#
        let session = try JSONDecoder().decode(
            ChatSession.self,
            from: try XCTUnwrap(oldJSON.data(using: .utf8))
        )

        XCTAssertNil(session.imageGenerationModelID)
    }

    func testOldJSONWithoutToolArgumentsStillDecodes() throws {
        // Predates toolArguments existing on disk at all -- must not fail to decode.
        let oldJSON = """
            {
                "id": "8A6D9E1B-2C1B-4A9E-9C1B-2C1B4A9E9C1B",
                "role": "tool",
                "content": "{\\"ok\\":true}",
                "reasoningContent": "",
                "createdAt": 0,
                "isStreaming": false,
                "isThinkingEnabled": false,
                "imageAttachments": [],
                "toolCalls": [],
                "toolCallID": "call_1",
                "toolName": "get_system_stats",
                "toolStatus": "succeeded"
            }
            """
        let message = try JSONDecoder().decode(ChatTranscriptMessage.self, from: XCTUnwrap(oldJSON.data(using: .utf8)))
        XCTAssertNil(message.toolArguments)
        XCTAssertEqual(message.toolStatus, .succeeded)
        XCTAssertEqual(message.toolName, "get_system_stats")
    }

    func testInteractiveAndDeclinedStatusesRoundTrip() throws {
        for status in [
            ChatTranscriptMessage.ToolStatus.awaitingConsent,
            .awaitingImageModelSelection,
            .declined,
        ] {
            let original = ChatTranscriptMessage(
                role: .tool,
                content: "",
                toolCallID: "call_1",
                toolName: ChatSwitchModelToolRegistry.toolName,
                toolStatus: status,
                toolArguments: #"{"model_id":"org/model"}"#
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ChatTranscriptMessage.self, from: data)
            XCTAssertEqual(decoded.toolStatus, status)
            XCTAssertEqual(decoded, original)
        }
    }

    func testFullRoundTripPreservesEquality() throws {
        let original = ChatTranscriptMessage(
            role: .tool,
            content: #"{"ok":true}"#,
            modelID: "org/model",
            toolCallID: "call_1",
            toolName: ChatSystemMonitorToolRegistry.toolName,
            toolStatus: .running,
            toolArguments: "{}"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatTranscriptMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
