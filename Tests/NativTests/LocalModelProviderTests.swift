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
}
