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
