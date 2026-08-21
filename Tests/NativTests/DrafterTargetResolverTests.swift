import Foundation
import XCTest

final class DrafterTargetResolverTests: XCTestCase {
    func testPrefersCurrentModelWhenCompatible() {
        let current = makeChatModel(repoID: "mlx-community/Qwen3.8-27B-8bit", hiddenSize: 5_120)
        let other = makeChatModel(repoID: "mlx-community/Other-7B-8bit", hiddenSize: 5_120)
        let drafter = makeDrafter(repoID: "mlx-community/Qwen3.8-27B-MTP-8bit", hiddenSize: 5_120)

        let resolved = DrafterTargetResolver.compatibleTarget(
            for: drafter,
            currentModelID: current.repoID,
            models: [current, other, drafter]
        )

        XCTAssertEqual(resolved?.repoID, current.repoID)
    }

    func testFallsBackToDerivedNameWhenCurrentModelIsIncompatible() {
        let current = makeChatModel(repoID: "mlx-community/Unrelated-7B-8bit", hiddenSize: 2_048)
        let paired = makeChatModel(repoID: "mlx-community/Qwen3.8-27B-8bit", hiddenSize: 5_120)
        let drafter = makeDrafter(repoID: "mlx-community/Qwen3.8-27B-MTP-8bit", hiddenSize: 5_120)

        let resolved = DrafterTargetResolver.compatibleTarget(
            for: drafter,
            currentModelID: current.repoID,
            models: [current, paired, drafter]
        )

        XCTAssertEqual(resolved?.repoID, paired.repoID)
    }

    func testFallsBackToFirstCompatibleChatModelWhenNameDerivationMisses() {
        let current = makeChatModel(repoID: "mlx-community/Unrelated-7B-8bit", hiddenSize: 2_048)
        let compatible = makeChatModel(repoID: "mlx-community/SameHidden-9B-4bit", hiddenSize: 5_120)
        let drafter = makeDrafter(repoID: "mlx-community/Qwen3.8-27B-MTP-8bit", hiddenSize: 5_120)

        let resolved = DrafterTargetResolver.compatibleTarget(
            for: drafter,
            currentModelID: current.repoID,
            models: [current, compatible, drafter]
        )

        XCTAssertEqual(resolved?.repoID, compatible.repoID)
    }

    func testReturnsNilWhenNoChatModelIsCompatible() {
        let current = makeChatModel(repoID: "mlx-community/Unrelated-7B-8bit", hiddenSize: 2_048)
        let drafter = makeDrafter(repoID: "mlx-community/Qwen3.8-27B-MTP-8bit", hiddenSize: 5_120)

        let resolved = DrafterTargetResolver.compatibleTarget(
            for: drafter,
            currentModelID: current.repoID,
            models: [current, drafter]
        )

        XCTAssertNil(resolved)
    }

    func testMissingHiddenSizeMetadataCountsAsCompatible() {
        let target = makeChatModel(repoID: "mlx-community/Qwen3.8-27B-8bit", hiddenSize: nil)
        let drafter = makeDrafter(repoID: "mlx-community/Qwen3.8-27B-MTP-8bit", hiddenSize: 5_120)

        let resolved = DrafterTargetResolver.compatibleTarget(
            for: drafter,
            currentModelID: nil,
            models: [drafter, target]
        )

        XCTAssertEqual(resolved?.repoID, target.repoID)
    }

    func testTargetNameCandidatesStripDrafterMarker() {
        XCTAssertEqual(
            DrafterTargetResolver.targetNameCandidates(from: "mlx-community/Qwen3.8-27B-MTP-8bit"),
            ["mlx-community/Qwen3.8-27B-8bit"]
        )
        XCTAssertEqual(
            DrafterTargetResolver.targetNameCandidates(from: "org/Foo-EAGLE3-8bit"),
            ["org/Foo-8bit"]
        )
        XCTAssertEqual(
            DrafterTargetResolver.targetNameCandidates(from: "org/Plain-8bit"),
            []
        )
    }

    private func makeChatModel(repoID: String, hiddenSize: Int?) -> LocalModel {
        LocalModel(
            repoID: repoID,
            snapshotURL: nil,
            modifiedAt: nil,
            sizeBytes: nil,
            parameterCount: nil,
            quantizationBits: nil,
            quantizationGroupSize: nil,
            contextSize: nil,
            provider: nil,
            capabilities: [.text],
            drafterKind: nil,
            hiddenSize: hiddenSize
        )
    }

    private func makeDrafter(repoID: String, hiddenSize: Int?) -> LocalModel {
        LocalModel(
            repoID: repoID,
            snapshotURL: nil,
            modifiedAt: nil,
            sizeBytes: nil,
            parameterCount: nil,
            quantizationBits: nil,
            quantizationGroupSize: nil,
            contextSize: nil,
            provider: nil,
            capabilities: [.text, .drafter],
            drafterKind: "mtp",
            hiddenSize: hiddenSize
        )
    }
}
