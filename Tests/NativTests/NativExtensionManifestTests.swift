import Foundation
import NativExtensionSDK
import XCTest

final class NativExtensionManifestTests: XCTestCase {
    func testAudioReferenceManifestMatchesSDKContract() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repositoryRoot
            .appendingPathComponent("Extensions")
            .appendingPathComponent("VoiceDictation")
            .appendingPathComponent("Manifest.json")
        let manifest = try JSONDecoder().decode(
            NativExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        try NativExtensionManifestValidator.validate(
            manifest,
            hostVersion: "0.1.0"
        )
        XCTAssertEqual(manifest.id, "com.nativ.voice-dictation")
        XCTAssertEqual(manifest.displayName, "Audio")
        XCTAssertTrue(manifest.included)
        XCTAssertEqual(
            manifest.contributions.sidebar.map(\.id),
            ["com.nativ.voice-dictation.audio"]
        )
    }

    func testValidManifestPassesValidation() throws {
        let manifest = makeManifest()

        XCTAssertNoThrow(
            try NativExtensionManifestValidator.validate(
                manifest,
                hostVersion: "1.2.0"
            )
        )
    }

    func testManifestRejectsNewerHostRequirement() {
        let manifest = makeManifest(minimumNativVersion: "2.0.0")

        XCTAssertThrowsError(
            try NativExtensionManifestValidator.validate(
                manifest,
                hostVersion: "1.9.9"
            )
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionManifestError,
                .incompatibleHost(required: "2.0.0", current: "1.9.9")
            )
        }
    }

    func testManifestRejectsDuplicateContributionIdentifiers() {
        let duplicateID = "com.example.extension.action"
        let manifest = NativExtensionManifest(
            id: "com.example.extension",
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "Example",
            summary: "Example extension",
            developer: "Example",
            systemImage: "puzzlepiece.extension",
            included: false,
            runtime: .extensionFoundation,
            runtimeBundleIdentifier: "com.example.extension.runtime",
            contributions: .init(
                sidebar: [
                    .init(
                        id: duplicateID,
                        title: "Example",
                        systemImage: "puzzlepiece.extension"
                    )
                ],
                commands: [
                    .init(id: duplicateID, title: "Example")
                ]
            )
        )

        XCTAssertThrowsError(
            try NativExtensionManifestValidator.validate(
                manifest,
                hostVersion: "1.0.0"
            )
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionManifestError,
                .duplicateContribution(duplicateID)
            )
        }
    }

    func testSemanticVersionComparison() throws {
        let older = try XCTUnwrap(NativSemanticVersion("1.4.9"))
        let newer = try XCTUnwrap(NativSemanticVersion("1.5.0-beta.1"))

        XCTAssertLessThan(older, newer)
        XCTAssertEqual(newer.description, "1.5.0")
    }

    func testExtensionFoundationManifestRequiresRuntimeBundleIdentifier() {
        let manifest = NativExtensionManifest(
            id: "com.example.extension",
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "Example",
            summary: "Example extension",
            developer: "Example",
            systemImage: "puzzlepiece.extension",
            included: false,
            runtime: .extensionFoundation
        )

        XCTAssertThrowsError(
            try NativExtensionManifestValidator.validate(
                manifest,
                hostVersion: "1.0.0"
            )
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionManifestError,
                .missingRuntimeBundleIdentifier
            )
        }
    }

    func testContributionIdentifierMustBelongToExtension() {
        let manifest = NativExtensionManifest(
            id: "com.example.extension",
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "Example",
            summary: "Example extension",
            developer: "Example",
            systemImage: "puzzlepiece.extension",
            included: false,
            runtime: .extensionFoundation,
            runtimeBundleIdentifier: "com.example.extension.runtime",
            contributions: .init(
                commands: [
                    .init(id: "com.other.action", title: "Invalid")
                ]
            )
        )

        XCTAssertThrowsError(
            try NativExtensionManifestValidator.validate(
                manifest,
                hostVersion: "1.0.0"
            )
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionManifestError,
                .invalidContributionIdentifier("com.other.action")
            )
        }
    }

    private func makeManifest(
        minimumNativVersion: String = "1.0.0"
    ) -> NativExtensionManifest {
        NativExtensionManifest(
            id: "com.example.extension",
            version: "1.0.0",
            minimumNativVersion: minimumNativVersion,
            displayName: "Example",
            summary: "Example extension",
            developer: "Example",
            systemImage: "puzzlepiece.extension",
            included: false,
            runtime: .extensionFoundation,
            runtimeBundleIdentifier: "com.example.extension.runtime"
        )
    }
}
