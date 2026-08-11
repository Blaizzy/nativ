import Foundation
import XCTest

final class LocalModelCapabilityOverlayTests: XCTestCase {
    private func model(
        repoID: String,
        snapshotPath: String? = nil,
        capabilities: Set<LocalModelCapability> = [.imageGeneration]
    ) -> LocalModel {
        LocalModel(
            repoID: repoID,
            snapshotURL: snapshotPath.map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            },
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

    func testOverlayByRepoIDReplacesImageFlags() {
        let overlay = model(repoID: "org/flux2").overlaying(
            serverCapabilities: [
                "org/flux2": ["image_generation", "image_editing"]
            ]
        )
        XCTAssertEqual(
            overlay.capabilities,
            [.imageGeneration, .imageEditing]
        )
    }

    func testOverlayBySnapshotPath() {
        let overlay = model(
            repoID: "local/anything",
            snapshotPath: "/models/snapshots/FLUX.2-klein"
        ).overlaying(
            serverCapabilities: [
                "/models/snapshots/FLUX.2-klein": ["image_editing"]
            ]
        )
        // Server truth says edit-only: generation flag must be removed.
        XCTAssertEqual(overlay.capabilities, [.imageEditing])
    }

    func testOverlayByLastPathComponent() {
        let overlay = model(
            repoID: "local/anything",
            snapshotPath: "/models/snapshots/mage-edit"
        ).overlaying(
            serverCapabilities: [
                "/Library/Caches/mage-edit": ["image_generation", "image_editing"]
            ]
        )
        XCTAssertEqual(
            overlay.capabilities,
            [.imageGeneration, .imageEditing]
        )
    }

    func testNoMatchKeepsLocalFlags() {
        let local = model(
            repoID: "org/bonsai",
            capabilities: [.imageGeneration, .imageEditing]
        )
        let overlay = local.overlaying(
            serverCapabilities: ["org/flux2": ["image_generation", "image_editing"]]
        )
        XCTAssertEqual(overlay, local)
    }

    func testUnknownServerTokensAreIgnored() {
        let overlay = model(repoID: "org/flux2").overlaying(
            serverCapabilities: [
                "org/flux2": ["image_generation", "mystery_capability"]
            ]
        )
        XCTAssertEqual(overlay.capabilities, [.imageGeneration])
    }

    func testEmptyServerCapabilitiesKeepLocalFlags() {
        let local = model(
            repoID: "org/bonsai",
            capabilities: [.imageGeneration]
        )
        let overlay = local.overlaying(serverCapabilities: [:])
        XCTAssertEqual(overlay, local)
    }

    func testServerTruthRemovesUnsupportedEditing() {
        // Server says generation-only (unknown model with Bonsai weights):
        // local heuristic wrongly added .imageEditing; server removes it.
        let local = model(
            repoID: "org/bonsai-2",
            capabilities: [.imageGeneration, .imageEditing]
        )
        let overlay = local.overlaying(
            serverCapabilities: ["org/bonsai-2": ["image_generation"]]
        )
        XCTAssertEqual(overlay.capabilities, [.imageGeneration])
    }
}
