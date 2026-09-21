import Foundation
import XCTest

final class ChatImageModelSelectionRequestTests: XCTestCase {
    func testHighlightStartsOnTheFirstDownloadedModel() {
        XCTAssertEqual(
            makeRequest(installed: ["org/a", "org/b"], downloadable: ["org/c"])
                .effectiveHighlightedModelID,
            "org/a"
        )
        XCTAssertNil(
            makeRequest(installed: [], downloadable: ["org/c"]).effectiveHighlightedModelID
        )
    }

    func testHighlightMovesThroughDownloadedModelsAndStopsAtTheEnds() {
        let request = makeRequest(installed: ["org/a", "org/b"], downloadable: ["org/c"])

        XCTAssertEqual(request.movingHighlight(by: -1).effectiveHighlightedModelID, "org/a")
        XCTAssertEqual(request.movingHighlight(by: 1).effectiveHighlightedModelID, "org/b")
        XCTAssertEqual(
            request.movingHighlight(by: 1).movingHighlight(by: 1).effectiveHighlightedModelID,
            "org/b"
        )
    }

    func testASingleDownloadedModelCannotMove() {
        let request = makeRequest(installed: ["org/a"], downloadable: ["org/b"])

        XCTAssertFalse(request.canMoveHighlight)
        XCTAssertNil(request.movingHighlight(by: 1).highlightedModelID)
    }

    func testHighlightFallsBackWhenTheModelIsNoLongerDownloaded() {
        var request = makeRequest(installed: ["org/a", "org/b"], downloadable: [])
        request.highlightedModelID = "org/removed"

        XCTAssertEqual(request.effectiveHighlightedModelID, "org/a")
    }

    func testRefreshingModelsKeepsTheHighlightAndOwningChat() {
        var request = makeRequest(installed: ["org/a", "org/b"], downloadable: [])
            .movingHighlight(by: 1)
        let chat = UUID()
        request.sessionID = chat

        request.models += [option(repoID: "org/c", availability: .installed)]

        XCTAssertEqual(request.effectiveHighlightedModelID, "org/b")
        XCTAssertEqual(request.sessionID, chat)
    }

    func testOnlyListedModelsAreOffered() {
        let request = makeRequest(installed: ["org/a"], downloadable: ["org/b"])

        XCTAssertTrue(request.offers("org/a"))
        XCTAssertTrue(request.offers("org/b"))
        XCTAssertFalse(request.offers("org/some-unrelated-llm"))
    }

    private func makeRequest(
        installed: [String],
        downloadable: [String]
    ) -> ChatImageModelSelectionRequest {
        ChatImageModelSelectionRequest(
            operation: .generate,
            models: installed.map { option(repoID: $0, availability: .installed) }
                + downloadable.map {
                    option(repoID: $0, availability: .downloadable(sizeBytes: 1_000))
                }
        )
    }

    private func option(
        repoID: String,
        availability: ChatImageModelOption.Availability
    ) -> ChatImageModelOption {
        ChatImageModelOption(
            displayName: repoID,
            modelID: repoID,
            capabilities: [.imageGeneration],
            availability: availability
        )
    }
}
