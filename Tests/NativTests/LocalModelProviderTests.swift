import NativServerKit
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

    func testHuggingFaceOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "HuggingFaceTB/SmolLM3-3B",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .huggingFace)
        XCTAssertEqual(provider?.displayName, "Hugging Face")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-huggingface")
    }

    func testRepublishedSmolVLMModelResolvesToHuggingFace() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "mlx-community/SmolVLM2-2.2B-Instruct-4bit",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .huggingFace)
    }

    func testStepFunOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "stepfun-ai/step3",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .stepFun)
        XCTAssertEqual(provider?.displayName, "StepFun")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-stepfun")
    }

    func testInternLMOrganizationResolvesToProvider() {
        let provider = LocalModelProviderResolver.resolve(
            repoID: "internlm/internlm3-8b-instruct",
            modelType: nil,
            architectures: []
        )

        XCTAssertEqual(provider, .internLM)
        XCTAssertEqual(provider?.displayName, "InternLM")
        XCTAssertEqual(provider?.iconResourceName, "ModelProviderIcon-internlm")
    }
}

final class HuggingFaceCapabilityFilterTests: XCTestCase {
    func testEmptyCapabilitySelectionUsesOneUnfilteredQuery() {
        XCTAssertEqual(
            HuggingFaceCapabilityFilter.queryVariants(for: []),
            [.init(pipelineTag: nil, tags: [])]
        )
    }

    func testFeatureQueriesCoverEveryClassifiedAlias() throws {
        for reasoning in ["reasoning", "thinking"] {
            for tools in ["tool-calling", "function-calling", "tool-use"] {
                let model = try decodeModel(pipelineTag: "text-generation", tags: [reasoning, tools])
                let selected: Set<LocalModelCapability> = [.reasoning, .tools]
                XCTAssertTrue(HuggingFaceCapabilityFilter.matches(model, capabilities: selected))
                XCTAssertTrue(queryCanReturn(model, capabilities: selected))
            }
        }
    }

    func testCombinedFeatureFilterRequiresBothCapabilities() throws {
        for tags in [["thinking"], ["function-calling"], []] {
            let model = try decodeModel(pipelineTag: "text-generation", tags: tags)
            XCTAssertFalse(HuggingFaceCapabilityFilter.matches(
                model, capabilities: [.reasoning, .tools]
            ))
        }
    }

    func testEveryCapabilityMetadataSignalHasACompatibleQuery() throws {
        let fixtures: [(LocalModelCapability, String, [String])] = [
            (.text, "text-generation", []),
            (.text, "image-text-to-text", []),
            (.text, "", ["conversational"]),
            (.vision, "visual-question-answering", []),
            (.vision, "", ["vision-language"]),
            (.audio, "audio-text-to-text", []),
            (.video, "image-to-video", []),
            (.video, "", ["video"]),
            (.imageGeneration, "text-to-image", []),
            (.imageEditing, "image-text-to-image", []),
            (.speechToText, "automatic-speech-recognition", []),
            (.speechToText, "", ["asr"]),
            (.textToSpeech, "", ["tts"]),
            (.embeddings, "sentence-similarity", []),
            (.embeddings, "", ["sentence-transformers"]),
            (.reranking, "text-ranking", []),
            (.reranking, "text-classification", ["base_model:org/model-reranker"]),
            (.reasoning, "text-generation", ["thinking"]),
            (.tools, "text-generation", ["function-calling"]),
            (.drafter, "text-generation", ["draft-model"]),
        ]

        for (capability, pipelineTag, tags) in fixtures {
            let model = try decodeModel(pipelineTag: pipelineTag, tags: tags)
            XCTAssertTrue(model.capabilities.contains(capability), "Missing badge for \(capability)")
            XCTAssertTrue(
                queryCanReturn(model, capabilities: [capability]),
                "No compatible query for \(capability)"
            )
        }
    }

    func testIncidentalMetadataDoesNotCreateFeatureBadges() throws {
        let model = try decodeModel(
            pipelineTag: "text-generation",
            libraryName: "thinking-tools",
            tags: ["base_model:org/model-thinking", "dataset:org/function-calling", "toolkit"]
        )
        XCTAssertFalse(model.capabilities.contains(.reasoning))
        XCTAssertFalse(model.capabilities.contains(.tools))
    }

    func testInstalledVisionLanguageModelsSurviveTextFilter() throws {
        for id in ["mlx-community/Qwen3.5-9B-MLX-4bit", "mlx-community/Muse-Glimmer-30B-4bit"] {
            let model = try decodeModel(id: id, pipelineTag: "image-text-to-text")
            XCTAssertTrue(HuggingFaceCapabilityFilter.matches(model, capabilities: [.text]))
            XCTAssertTrue(queryCanReturn(model, capabilities: [.text]))
        }
    }

    func testAudioDoesNotAbsorbSpeechOnlyModels() throws {
        let speechToText = try decodeModel(
            pipelineTag: "automatic-speech-recognition",
            tags: ["speech", "audio", "asr"]
        )
        let textToSpeech = try decodeModel(
            pipelineTag: "text-to-speech",
            tags: ["speech", "audio", "tts"]
        )

        XCTAssertEqual(speechToText.capabilities, [.speechToText])
        XCTAssertEqual(textToSpeech.capabilities, [.textToSpeech])
        XCTAssertFalse(queryCanReturn(speechToText, capabilities: [.audio]))
        XCTAssertFalse(queryCanReturn(textToSpeech, capabilities: [.audio]))
    }

    func testReportedHiddenModelsMatchTheirDiscoveryQueries() throws {
        let fixtures: [(HuggingFaceModel, LocalModelCapability)] = [
            (
                try decodeModel(
                    id: "mlx-community/Qwen3.8-27B-4bit",
                    pipelineTag: "image-text-to-text",
                    tags: ["conversational"]
                ),
                .text
            ),
            (
                try decodeModel(
                    id: "mlx-community/Qwen3.8-27B-Uncensored-OptiQ-4bit",
                    pipelineTag: "text-generation",
                    tags: ["reasoning", "function-calling", "tool-use"]
                ),
                .tools
            ),
            (
                try decodeModel(
                    id: "mlx-community/parakeet-tdt-0.6b-v3",
                    pipelineTag: "automatic-speech-recognition",
                    tags: ["speech", "audio", "asr"]
                ),
                .speechToText
            ),
            (
                try decodeModel(
                    id: "sentence-transformers/all-MiniLM-L6-v2",
                    pipelineTag: "sentence-similarity",
                    tags: ["sentence-transformers", "feature-extraction"]
                ),
                .embeddings
            ),
            (
                try decodeModel(
                    id: "heykorshun/bge-reranker-v2-m3-mlx-int8",
                    pipelineTag: "text-classification",
                    tags: ["base_model:BAAI/bge-reranker-v2-m3"]
                ),
                .reranking
            ),
            (
                try decodeModel(
                    id: "Qwen/Qwen-Image-Layered",
                    pipelineTag: "image-text-to-image"
                ),
                .imageEditing
            ),
        ]

        for (model, capability) in fixtures {
            XCTAssertTrue(model.capabilities.contains(capability))
            XCTAssertTrue(queryCanReturn(model, capabilities: [capability]))
        }
    }

    func testCombinedFiltersStayBoundedAndConstrained() {
        let capabilities = Set(LocalModelCapability.allCases)
        let variants = HuggingFaceCapabilityFilter.queryVariants(for: capabilities)

        XCTAssertFalse(variants.isEmpty)
        XCTAssertLessThanOrEqual(variants.count, 32)
        XCTAssertTrue(variants.allSatisfy { $0.pipelineTag != nil || !$0.tags.isEmpty })
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

    func testBroadSpeculativeDecodingCandidateUsesConfigMetadata() throws {
        let model = try decodeModel(
            pipelineTag: "text-generation",
            tags: ["speculative-decoding"],
            config: [
                "model_type": "qwen3",
                "architectures": ["DFlashDraftModel"],
                "dflash_config": [:],
            ]
        )

        XCTAssertTrue(model.capabilities.contains(.drafter))
        XCTAssertEqual(model.drafterKind, "dflash")
        XCTAssertTrue(queryCanReturn(model, capabilities: [.drafter]))
    }

    func testMalformedDrafterConfigDoesNotBreakHubModelDecoding() throws {
        let model = try decodeModel(
            pipelineTag: "text-generation",
            tags: ["draft-model"],
            config: [
                "model_type": 42,
                "architectures": "DFlashDraftModel",
                "dflash_config": "invalid",
                "markov_rank": "invalid",
            ]
        )

        XCTAssertTrue(model.capabilities.contains(.drafter))
        XCTAssertNil(model.drafterKind)
    }

    func testGGUFTaggedSafetensorsRepositoryIsIdentifiedAsGGUF() throws {
        let model = try decodeModel(
            id: "test/model-GGUF",
            pipelineTag: "text-generation",
            tags: ["safetensors", "gguf"],
            safetensors: ["parameters": ["F16": 1_000]]
        )

        XCTAssertTrue(model.isGGUF)
    }

    func testGGUFIdentificationChecksEachMetadataFieldIgnoringCase() throws {
        let models = [
            try decodeModel(id: "test/model-GgUf", pipelineTag: "text-generation"),
            try decodeModel(pipelineTag: "text-generation", libraryName: "GGUF"),
            try decodeModel(pipelineTag: "text-generation", tags: ["safetensors", "gguf"]),
        ]

        for model in models {
            XCTAssertTrue(model.isGGUF, "Expected GGUF metadata to exclude \(model.id)")
        }
    }

    func testSafetensorsRepositoryWithoutGGUFMetadataIsNotExcluded() throws {
        let model = try decodeModel(
            id: "mlx-community/model-4bit",
            pipelineTag: "text-generation",
            libraryName: "mlx",
            tags: ["safetensors", "4-bit"],
            safetensors: ["parameters": ["F16": 1_000]]
        )

        XCTAssertFalse(model.isGGUF)
        XCTAssertTrue(HuggingFaceCapabilityFilter.matches(model, capabilities: [.text]))
    }

    func testMissingOptionalMetadataDoesNotIdentifyRepositoryAsGGUF() throws {
        let model = try decodeModel(pipelineTag: "text-generation")

        XCTAssertFalse(model.isGGUF)
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

    private func queryCanReturn(
        _ model: HuggingFaceModel,
        capabilities: Set<LocalModelCapability>
    ) -> Bool {
        let modelTags = Set(model.tags.map { $0.lowercased() })
        return HuggingFaceCapabilityFilter.queryVariants(for: capabilities).contains {
            ($0.pipelineTag == nil || $0.pipelineTag == model.pipelineTag?.lowercased())
                && Set($0.tags).isSubset(of: modelTags)
        }
    }

    private func decodeModel(
        id: String = "test/model",
        pipelineTag: String,
        libraryName: String? = nil,
        tags: [String] = [],
        safetensors: [String: Any]? = nil,
        config: [String: Any]? = nil
    ) throws -> HuggingFaceModel {
        var payload: [String: Any] = [
            "id": id,
            "pipeline_tag": pipelineTag,
            "tags": tags,
        ]
        payload["library_name"] = libraryName
        payload["safetensors"] = safetensors
        payload["config"] = config
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(HuggingFaceModel.self, from: data)
    }
}

final class NativModelTypeRegistryDrafterTests: XCTestCase {
    func testDrafterKindsFollowCanonicalLoaderAndAliases() throws {
        var capabilities: [String: Any] = [:]
        for capability in NativModelCapability.allCases {
            capabilities[capability.rawValue] = [
                "model_types": ["test_\(capability.rawValue)"],
                "aliases": [:],
            ]
        }
        capabilities[NativModelCapability.speculativeDrafters.rawValue] = [
            "model_types": ["qwen3_dflash"],
            "aliases": ["qwen3-dflash": "qwen3_dflash"],
            "kinds": ["qwen3_dflash": "dflash"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "package_versions": ["mlx-vlm": "1.0", "mlx-audio": "1.0"],
            "capabilities": capabilities,
        ])

        let registry = try NativModelTypeRegistry(data: data)

        XCTAssertEqual(registry.drafterKind(for: "qwen3_dflash"), "dflash")
        XCTAssertEqual(registry.drafterKind(for: "qwen3-dflash"), "dflash")
        XCTAssertNil(registry.drafterKind(for: "qwen3"))
    }

    func testDrafterKindsRejectUnknownRuntimeKinds() throws {
        var capabilities: [String: Any] = [:]
        for capability in NativModelCapability.allCases {
            capabilities[capability.rawValue] = [
                "model_types": ["test_\(capability.rawValue)"],
                "aliases": [:],
            ]
        }
        capabilities[NativModelCapability.speculativeDrafters.rawValue] = [
            "model_types": ["future_drafter"],
            "aliases": [:],
            "kinds": ["future_drafter": "unknown"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "package_versions": ["mlx-vlm": "1.0", "mlx-audio": "1.0"],
            "capabilities": capabilities,
        ])

        XCTAssertThrowsError(try NativModelTypeRegistry(data: data)) { error in
            XCTAssertEqual(
                error as? NativModelTypeRegistryError,
                .invalidModelKind(
                    "future_drafter",
                    "unknown",
                    .speculativeDrafters
                )
            )
        }
    }
}

final class ModelDownloadProgressTests: XCTestCase {
    func testInvalidTotalIsUnknown() {
        let progress = ModelDownloadProgress(totalBytes: 0)

        XCTAssertNil(progress.totalBytes)
        XCTAssertEqual(progress.fractionCompleted, 0)
        XCTAssertNil(progress.remainingBytes)
    }

    func testCompletedBytesAreClampedToTotal() throws {
        let progress = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 120, totalBytes: 100)
        )

        XCTAssertEqual(progress.completedBytes, 100)
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.remainingBytes, 0)
    }

    func testMergeIsMonotonicForTheSameTotal() throws {
        var progress = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 50, totalBytes: 100)
        )
        let olderUpdate = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 25, totalBytes: 100)
        )

        XCTAssertFalse(progress.merge(olderUpdate))
        XCTAssertEqual(progress.completedBytes, 50)
    }
}

final class ModelDownloadProgressLimiterTests: XCTestCase {
    func testCoalescesUpdatesWithinPublishIntervalAndFlushesLatest() throws {
        let clock = ContinuousClock()
        let start = clock.now
        let initial = ModelDownloadProgress(totalBytes: 1_000)
        var limiter = ModelDownloadProgressLimiter()

        let first = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 100, totalBytes: 1_000)
        )
        XCTAssertEqual(limiter.submit(first, current: initial, at: start), first)

        let second = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 200, totalBytes: 1_000)
        )
        XCTAssertNil(
            limiter.submit(
                second,
                current: first,
                at: start.advanced(by: .milliseconds(25))
            )
        )

        let latest = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 300, totalBytes: 1_000)
        )
        XCTAssertNil(
            limiter.submit(
                latest,
                current: first,
                at: start.advanced(by: .milliseconds(75))
            )
        )
        XCTAssertEqual(
            limiter.flush(at: start.advanced(by: .milliseconds(100))),
            latest
        )
    }

    func testPublishesCompletionImmediately() throws {
        let clock = ContinuousClock()
        let start = clock.now
        let initial = ModelDownloadProgress(totalBytes: 1_000)
        var limiter = ModelDownloadProgressLimiter()
        let first = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 100, totalBytes: 1_000)
        )
        _ = limiter.submit(first, current: initial, at: start)

        let complete = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 1_000, totalBytes: 1_000)
        )
        XCTAssertEqual(
            limiter.submit(
                complete,
                current: first,
                at: start.advanced(by: .milliseconds(10))
            ),
            complete
        )
        XCTAssertNil(limiter.pending)
    }
}

final class HuggingFaceDownloadOutputTests: XCTestCase {
    func testParsesProgress() throws {
        let output = try XCTUnwrap(
            HuggingFaceDownloadOutput(line: "__NATIV_PROGRESS__:34:80")
        )
        guard case .progress(let progress) = output else {
            return XCTFail("Expected a progress event")
        }

        XCTAssertEqual(progress.completedBytes, 34)
        XCTAssertEqual(progress.totalBytes, 80)
    }

    func testParsesTransferredBytes() {
        XCTAssertEqual(
            HuggingFaceDownloadOutput(line: "__NATIV_TRANSFERRED__:2048"),
            .transferredBytes(2_048)
        )
    }

    func testRejectsMalformedOutput() {
        XCTAssertNil(HuggingFaceDownloadOutput(line: "__NATIV_PROGRESS__:34:0"))
        XCTAssertNil(HuggingFaceDownloadOutput(line: "ordinary log output"))
    }

    func testClassifiesGatedRepositoryFailure() {
        let failure = HuggingFaceDownloadFailure(processOutput: """
        huggingface_hub.errors.GatedRepoError: 403 Client Error.
        Cannot access gated repo for url https://huggingface.co/org/model/resolve/main/config.json.
        Access to model org/model is restricted and you are not in the authorized list.
        """)

        XCTAssertEqual(failure, .gatedRepository)
    }

    func testKeepsUsefulLinesForUnknownDownloadFailure() {
        let failure = HuggingFaceDownloadFailure(processOutput: """
        first line
        second line
        third line
        fourth line
        fifth line
        """)

        XCTAssertEqual(
            failure,
            .message("second line\nthird line\nfourth line\nfifth line")
        )
    }
}

final class HuggingFaceDownloadProgressStateTests: XCTestCase {
    func testProgressIsMonotonicAndResetsTheStallDeadline() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = HuggingFaceDownloadProgressState(now: start)
        let first = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 25, totalBytes: 100)
        )
        let older = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 10, totalBytes: 100)
        )

        XCTAssertEqual(state.recordProgress(first, at: start), first)
        XCTAssertNil(state.recordProgress(older, at: start.addingTimeInterval(1)))
        XCTAssertFalse(
            state.isStalled(at: start.addingTimeInterval(59), timeout: 60, isPaused: false)
        )
        XCTAssertTrue(
            state.isStalled(at: start.addingTimeInterval(60), timeout: 60, isPaused: false)
        )
    }

    func testPausedDownloadNeverTriggersRecovery() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        let state = HuggingFaceDownloadProgressState(now: start)

        XCTAssertFalse(
            state.isStalled(at: start.addingTimeInterval(600), timeout: 60, isPaused: true)
        )
    }

    func testNearCompleteProgressUsesFinishingState() throws {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var state = HuggingFaceDownloadProgressState(now: start)
        let progress = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 950, totalBytes: 1_000)
        )

        _ = state.recordProgress(progress, at: start)

        XCTAssertTrue(state.isFinishing)
    }

    func testTransferEstimateCeilingUsesFinishingState() throws {
        let start = Date(timeIntervalSinceReferenceDate: 3_500)
        var state = HuggingFaceDownloadProgressState(now: start)
        let initial = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 0, totalBytes: 1_001)
        )

        _ = state.recordProgress(initial, at: start)
        let capped = try XCTUnwrap(
            state.recordTransferredBytes(2_000, at: start.addingTimeInterval(1))
        )

        XCTAssertEqual(capped.completedBytes, 951)
        XCTAssertLessThan(capped.fractionCompleted, 1)
        XCTAssertTrue(state.isFinishing)
    }

    func testTransferredBytesProduceSmoothedTransferSpeed() {
        let start = Date(timeIntervalSinceReferenceDate: 4_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        _ = state.recordTransferredBytes(1_000, at: start.addingTimeInterval(1))
        XCTAssertEqual(state.bytesPerSecond, 1_000)

        _ = state.recordTransferredBytes(3_000, at: start.addingTimeInterval(2))
        XCTAssertEqual(state.bytesPerSecond, 1_350)
    }

    func testTransferBytesAdvanceProgressBetweenReconstructionUpdates() throws {
        let start = Date(timeIntervalSinceReferenceDate: 5_000)
        var state = HuggingFaceDownloadProgressState(now: start)
        let initial = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 0, totalBytes: 1_000)
        )
        let reconstructed = try XCTUnwrap(
            ModelDownloadProgress(completedBytes: 200, totalBytes: 1_000)
        )

        _ = state.recordProgress(initial, at: start)
        XCTAssertEqual(
            state.recordTransferredBytes(100, at: start.addingTimeInterval(0.1))?.completedBytes,
            100
        )
        _ = state.recordProgress(reconstructed, at: start.addingTimeInterval(0.2))
        XCTAssertEqual(
            state.recordTransferredBytes(200, at: start.addingTimeInterval(0.3))?.completedBytes,
            350
        )
    }

    func testTransferSpeedBecomesUnknownWhenStale() {
        let start = Date(timeIntervalSinceReferenceDate: 6_000)
        var state = HuggingFaceDownloadProgressState(now: start)

        _ = state.recordTransferredBytes(1_000, at: start.addingTimeInterval(1))
        XCTAssertEqual(state.transferSpeed(at: start.addingTimeInterval(2)), 1_000)
        XCTAssertNil(state.transferSpeed(at: start.addingTimeInterval(3)))
    }
}

final class ModelDownloadProgressPresentationTests: XCTestCase {
    private let testLocale = Locale(identifier: "en_US_POSIX")

    func testActiveDownloadNeverDisplaysOneHundredPercent() {
        XCTAssertEqual(ModelDownloadProgressPresentation.activePercentage(0), 0)
        XCTAssertEqual(ModelDownloadProgressPresentation.activePercentage(0.994), 99)
        XCTAssertEqual(ModelDownloadProgressPresentation.activePercentage(1), 99)
    }

    func testNearCompleteDownloadUsesFinishingState() {
        XCTAssertFalse(ModelDownloadProgressPresentation.isFinishing(0.949))
        XCTAssertTrue(ModelDownloadProgressPresentation.isFinishing(0.95))
        XCTAssertTrue(ModelDownloadProgressPresentation.isFinishing(1))
    }

    func testActiveProgressRingDoesNotBecomeComplete() {
        XCTAssertEqual(ModelDownloadProgressPresentation.ringProgress(1), 0.99)
    }

    func testTransferSpeedFormatting() {
        XCTAssertNil(ModelDownloadProgressPresentation.formattedSpeed(nil))
        XCTAssertEqual(
            ModelDownloadProgressPresentation.formattedSpeed(0, locale: testLocale),
            "0 B/s"
        )
        XCTAssertEqual(
            ModelDownloadProgressPresentation.formattedSpeed(
                1_000_000,
                locale: testLocale
            ),
            "1 MB/s"
        )
    }

    func testByteProgressFormatting() throws {
        let progress = try XCTUnwrap(
            ModelDownloadProgress(
                completedBytes: 3_400_000_000,
                totalBytes: 8_000_000_000
            )
        )

        XCTAssertEqual(
            ModelDownloadProgressPresentation.formattedByteProgress(
                progress,
                locale: testLocale
            ),
            "3.4 GB / 8 GB"
        )
    }
}
