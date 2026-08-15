import XCTest

final class LocalModelProviderTests: XCTestCase {
    func testStabilityAIOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "stabilityai/stable-diffusion-3.5-large",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .stabilityAI)
        XCTAssertEqual(provider?.displayName, "Stability AI")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-stability")
    }

    func testThinkingMachinesOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "thinkingmachines/Inkling",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .thinkingMachines)
        XCTAssertEqual(provider?.displayName, "Thinking Machines")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-thinking-machines")
    }

    func testMeituanLongCatOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "meituan-longcat/LongCat-Flash-Chat",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .meituanLongCat)
        XCTAssertEqual(provider?.displayName, "Meituan LongCat")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-longcat")
    }

    func testMoonshotOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "moonshotai/Kimi-K2.5",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .moonshotAI)
        XCTAssertEqual(provider?.displayName, "Moonshot AI")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-moonshot")
    }

    func testMiniMaxOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "MiniMaxAI/MiniMax-M2.5",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .miniMax)
        XCTAssertEqual(provider?.displayName, "MiniMax")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-minimax")
    }

    func testBaiduOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "baidu/ERNIE-Image",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .baidu)
        XCTAssertEqual(provider?.displayName, "Baidu")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-baidu")
    }

    func testInclusionAIOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "inclusionAI/Ling-mini-2.0",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .inclusionAI)
        XCTAssertEqual(provider?.displayName, "InclusionAI")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-inclusionai")
    }

    func testMetaModelsOrganizationResolvesToMetaProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "meta-models/Muse-Glimmer-30B",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .meta)
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-meta")
    }

    func testRepublishedMuseGlimmerVariantsResolveToMetaProvider() {
        let repoIDs = [
            "mlx-community/Muse-Glimmer-30B-4bit",
            "unsloth/Muse-Glimmer-30B",
            "darkc0de/Muse-Glimmer-30B-heretic"
        ]

        for repoID in repoIDs {
            let provider = LocalModelProviderResolver.resolve(
                repoID: repoID,
                modelType: nil,
                architectures: []
            )

            XCTAssertEqual(provider, .meta, repoID)
            XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-meta", repoID)
        }
    }

    func testBlackForestLabsOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "black-forest-labs/FLUX.2-klein-9B-kv",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .blackForestLabs)
        XCTAssertEqual(provider?.displayName, "Black Forest Labs")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-bfl")
    }

    func testRepublishedFluxModelResolvesToBlackForestLabs() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "mlx-community/FLUX.2-klein-4b-8bit",
            modelType: "flux2",
            architectures: ["Flux2Transformer2DModel"]
        )

        XCTAssertEqual(provider, .blackForestLabs)
    }
}

final class HuggingFaceCapabilityFilterTests: XCTestCase {
    func testReasoningUsesCanonicalHubFilter() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.hubTags(for: [.reasoning]),
            ["reasoning"]
        )
    }

    func testToolCallingUsesCanonicalHubFilter() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.hubTags(for: [.tools]),
            ["tool-calling"]
        )
    }

    func testCombinedCapabilitiesUseBothCanonicalHubFilters() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.hubTags(for: [.tools, .reasoning]),
            ["reasoning", "tool-calling"]
        )
    }

    func testDrafterUsesCanonicalHubFilter() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.hubTags(for: [.drafter]),
            ["draft-model"]
        )
    }

    func testSupportedCapabilitiesUseCanonicalPipelineTasks() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.pipelineTag(for: [.text]),
            "text-generation"
        )
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.pipelineTag(for: [.audio]),
            "audio-text-to-text"
        )
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.pipelineTag(for: [.video]),
            "video-text-to-text"
        )
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.pipelineTag(for: [.embeddings]),
            "feature-extraction"
        )
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.pipelineTag(for: [.reranking]),
            "text-ranking"
        )
    }

    func testFeatureTagCanBeCombinedWithPipelineTask() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.pipelineTag(for: [.text, .reasoning]),
            "text-generation"
        )
    }

    func testSupportedHubTaskAliasesResolveToNativCapabilities() throws {
        XCTAssertEqual(
            try capabilities(for: "audio-text-to-text"),
            [.audio, .text]
        )
        XCTAssertEqual(
            try capabilities(for: "video-text-to-text"),
            [.video, .vision, .text]
        )
        XCTAssertEqual(
            try capabilities(for: "visual-question-answering"),
            [.vision, .text]
        )
        XCTAssertEqual(
            try capabilities(for: "image-text-to-image"),
            [.imageEditing]
        )
        XCTAssertEqual(
            try capabilities(for: "image-feature-extraction"),
            [.embeddings]
        )
        XCTAssertEqual(
            try capabilities(for: "sentence-similarity"),
            [.embeddings]
        )
        XCTAssertEqual(
            try capabilities(for: "text-ranking"),
            [.reranking]
        )
    }

    func testUnsupportedWorkflowTagsAreNotTreatedAsRunnableModels() throws {
        XCTAssertTrue(try capabilities(for: "any-to-any").isEmpty)
        XCTAssertTrue(try capabilities(for: "translation").isEmpty)
    }

    func testDrafterAliasesResolveToDrafterCapability() throws {
        for tag in ["draft-model", "drafter", "speculative-decoding-draft"] {
            XCTAssertTrue(
                try capabilities(for: "text-generation", tags: [tag]).contains(.drafter),
                "Expected \(tag) to resolve as a drafter"
            )
        }
    }

    func testBroadSpeculativeDecodingTagIsNotTreatedAsDrafter() throws {
        XCTAssertFalse(
            try capabilities(for: "text-generation", tags: ["speculative-decoding"])
                .contains(.drafter)
        )
    }

    func testGGUFTaggedSafetensorsRepositoryRemainsVisible() throws {
        let model = try decodeModel(
            id: "test/model-GGUF",
            pipelineTag: "text-generation",
            tags: ["safetensors", "gguf"],
            safetensors: ["parameters": ["F16": 1_000]]
        )

        XCTAssertTrue(
            HuggingFaceCapabilityFilter.matches(model, capabilities: [.text])
        )
    }

    func testGGUFArtifactsAreExcludedFromSnapshotDownloads() {
        XCTAssertEqual(
            HuggingFaceDownloadFilePolicy.ignoredPatterns,
            ["*.[gG][gG][uU][fF]"]
        )
        XCTAssertTrue(HuggingFaceDownloadFilePolicy.shouldIgnore(path: "model.gguf"))
        XCTAssertTrue(HuggingFaceDownloadFilePolicy.shouldIgnore(path: "weights/Model.GGUF"))
        XCTAssertFalse(
            HuggingFaceDownloadFilePolicy.shouldIgnore(path: "model.safetensors")
        )
    }

    private func capabilities(
        for pipelineTag: String,
        tags: [String] = []
    ) throws -> Set<LocalModelCapability> {
        try decodeModel(pipelineTag: pipelineTag, tags: tags).capabilities
    }

    private func decodeModel(
        id: String = "test/model",
        pipelineTag: String,
        tags: [String] = [],
        safetensors: [String: Any]? = nil
    ) throws -> HuggingFaceModel {
        var payload: [String: Any] = [
            "id": id,
            "pipeline_tag": pipelineTag,
            "tags": tags,
        ]
        payload["safetensors"] = safetensors
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(HuggingFaceModel.self, from: data)
    }
}

final class HuggingFaceDownloadProgressStateTests: XCTestCase {
    func testAllocatedBytesProvideMonotonicAggregateProgress() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        XCTAssertEqual(
            state.recordAllocatedBytes(25, expectedBytes: 100, at: start),
            0.25
        )
        XCTAssertNil(
            state.recordReportedProgress(0.10, at: start.addingTimeInterval(1))
        )
        XCTAssertEqual(state.progress, 0.25)
        XCTAssertEqual(
            state.recordAllocatedBytes(75, expectedBytes: 100, at: start.addingTimeInterval(2)),
            0.75
        )
    }

    func testNewCacheBytesResetTheStallDeadline() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        XCTAssertFalse(
            state.isStalled(at: start.addingTimeInterval(59), timeout: 60, isPaused: false)
        )
        XCTAssertEqual(
            state.recordAllocatedBytes(1, expectedBytes: 10, at: start.addingTimeInterval(59)),
            0.1
        )
        XCTAssertFalse(
            state.isStalled(at: start.addingTimeInterval(100), timeout: 60, isPaused: false)
        )
        XCTAssertTrue(
            state.isStalled(at: start.addingTimeInterval(119), timeout: 60, isPaused: false)
        )
    }

    func testPausedDownloadNeverTriggersRecovery() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        let state = HuggingFaceDownloadProgressState(now: start)

        XCTAssertFalse(
            state.isStalled(at: start.addingTimeInterval(600), timeout: 60, isPaused: true)
        )
    }

    func testNearCompleteProgressUsesFinalizingState() {
        let start = Date(timeIntervalSinceReferenceDate: 4_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        _ = state.recordReportedProgress(0.995, at: start)

        XCTAssertTrue(state.isFinalizing)
    }

    func testAllocatedBytesProduceSmoothedTransferSpeed() {
        let start = Date(timeIntervalSinceReferenceDate: 5_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        _ = state.recordAllocatedBytes(100, expectedBytes: nil, at: start)
        XCTAssertNil(state.bytesPerSecond)

        _ = state.recordAllocatedBytes(1_100, expectedBytes: nil, at: start.addingTimeInterval(1))
        XCTAssertEqual(state.bytesPerSecond, 1_000)

        _ = state.recordAllocatedBytes(3_100, expectedBytes: nil, at: start.addingTimeInterval(2))
        XCTAssertEqual(state.bytesPerSecond, 1_350)
    }

    func testTransferSpeedFallsToZeroAfterNoNewBytes() {
        let start = Date(timeIntervalSinceReferenceDate: 6_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        _ = state.recordAllocatedBytes(0, expectedBytes: nil, at: start)
        _ = state.recordAllocatedBytes(1_000, expectedBytes: nil, at: start.addingTimeInterval(1))
        XCTAssertNotNil(state.bytesPerSecond)

        _ = state.recordAllocatedBytes(1_000, expectedBytes: nil, at: start.addingTimeInterval(3))
        XCTAssertEqual(state.bytesPerSecond, 0)
    }
}

final class ModelDownloadProgressPresentationTests: XCTestCase {
    func testActiveDownloadNeverDisplaysOneHundredPercent() {
        XCTAssertEqual(ModelDownloadProgressPresentation.activePercentage(0), 0)
        XCTAssertEqual(ModelDownloadProgressPresentation.activePercentage(0.994), 99)
        XCTAssertEqual(ModelDownloadProgressPresentation.activePercentage(1), 99)
    }

    func testNearCompleteDownloadUsesFinalizingState() {
        XCTAssertFalse(ModelDownloadProgressPresentation.isFinalizing(0.994))
        XCTAssertTrue(ModelDownloadProgressPresentation.isFinalizing(0.995))
        XCTAssertTrue(ModelDownloadProgressPresentation.isFinalizing(1))
    }

    func testActiveProgressRingDoesNotBecomeComplete() {
        XCTAssertEqual(ModelDownloadProgressPresentation.ringProgress(1), 0.99)
    }

    func testTransferSpeedFormatting() {
        XCTAssertNil(ModelDownloadProgressPresentation.formattedSpeed(nil))
        XCTAssertEqual(ModelDownloadProgressPresentation.formattedSpeed(0), "0 B/s")
        XCTAssertTrue(
            ModelDownloadProgressPresentation.formattedSpeed(1_000_000)?.hasSuffix("/s") == true
        )
    }
}
