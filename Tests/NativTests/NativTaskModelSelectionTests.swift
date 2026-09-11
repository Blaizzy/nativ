import Foundation
import NativExtensionSDK
import XCTest

final class NativTaskModelSelectionTests: XCTestCase {
    private func model(
        _ repoID: String,
        _ capabilities: Set<LocalModelCapability>
    ) -> LocalModel {
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
            capabilities: capabilities,
            drafterKind: nil,
            hiddenSize: nil
        )
    }

    private lazy var installed: [LocalModel] = [
        model("org/zeta-chat", [.text]),
        model("org/alpha-chat", [.text]),
        model("org/see", [.vision]),
        model("org/draft", [.text, .drafter]),
        model("org/rank", [.reranking]),
        model("org/paint", [.imageGeneration]),
        model("org/hear", [.speechToText]),
    ]

    func testExplicitModelWins() {
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .language,
                requested: "org/zeta-chat",
                pinned: "org/alpha-chat",
                installed: installed
            ),
            .resolved(modelID: "org/zeta-chat", substitutedFor: nil)
        )
    }

    func testAutomaticDefersToThePin() {
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .language,
                requested: "automatic",
                pinned: "org/zeta-chat",
                installed: installed
            ),
            .resolved(modelID: "org/zeta-chat", substitutedFor: nil)
        )
    }

    /// A language model is fungible; an extension should not break because the
    /// author's choice is not installed.
    func testMissingRequestedModelFallsThroughAndReportsTheSubstitution() {
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .language,
                requested: "org/not-installed",
                pinned: "org/zeta-chat",
                installed: installed
            ),
            .resolved(modelID: "org/zeta-chat", substitutedFor: "org/not-installed")
        )
    }

    func testWithoutARequestOrPinTheChoiceIsDeterministic() {
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .language,
                requested: nil,
                pinned: nil,
                installed: installed
            ),
            .resolved(modelID: "org/alpha-chat", substitutedFor: nil)
        )
    }

    /// A pinned model that cannot serve the task is ignored, not handed work it
    /// cannot do. Vision shares the language pin, which is why this matters.
    func testPinIncompatibleWithTheTaskIsIgnored() {
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .vision,
                requested: nil,
                pinned: "org/alpha-chat",
                installed: installed
            ),
            .resolved(modelID: "org/see", substitutedFor: nil)
        )
    }

    func testNoCompatibleModelIsReportedPerTask() {
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .textToSpeech,
                requested: nil,
                pinned: nil,
                installed: installed
            ),
            .noCompatibleModel(task: .textToSpeech)
        )
        XCTAssertEqual(
            NativTaskModelSelection.resolve(
                task: .embedding,
                requested: nil,
                pinned: nil,
                installed: []
            ),
            .noCompatibleModel(task: .embedding)
        )
    }

    func testDraftersAndRerankersAreNotLanguageModels() {
        XCTAssertFalse(
            NativTaskModelSelection.isEligible(model("org/draft", [.text, .drafter]), for: .language)
        )
        XCTAssertFalse(
            NativTaskModelSelection.isEligible(model("org/rank", [.reranking]), for: .language)
        )
    }

    func testAVisionModelCanAlsoServeLanguage() {
        XCTAssertTrue(
            NativTaskModelSelection.isEligible(model("org/see", [.vision]), for: .language)
        )
        XCTAssertFalse(
            NativTaskModelSelection.isEligible(
                model("org/paint", [.imageGeneration, .vision]),
                for: .vision
            )
        )
    }

    func testEveryTaskMapsToASlot() {
        for task in NativWorkflowModelTask.allCases {
            XCTAssertNotNil(NativTaskModelSelection.preloadSlot(for: task))
        }
        XCTAssertEqual(NativTaskModelSelection.preloadSlot(for: .vision), .language)
    }
}
