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
    }

    func testUnsupportedWorkflowTagsAreNotTreatedAsRunnableModels() throws {
        XCTAssertTrue(try capabilities(for: "any-to-any").isEmpty)
        XCTAssertTrue(try capabilities(for: "translation").isEmpty)
        XCTAssertTrue(try capabilities(for: "text-ranking").isEmpty)
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
