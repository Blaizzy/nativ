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
        XCTAssertEqual(manifest.enabledByDefault, false)
        XCTAssertEqual(
            manifest.contributions.sidebar.map(\.id),
            ["com.nativ.voice-dictation.audio"]
        )
        XCTAssertEqual(
            manifest.contributions.shortcuts.map(\.id),
            [
                "com.nativ.voice-dictation.transcribe",
                "com.nativ.voice-dictation.retranscribe",
            ]
        )
        XCTAssertTrue(manifest.permissions.contains(.systemAudioCapture))
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

final class NativExtensionStateStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "NativExtensionStateStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testIncludedExtensionDefaultsToEnabled() {
        let store = NativExtensionStateStore(defaults: defaults)

        XCTAssertEqual(store.state(for: makeManifest(included: true)), .enabled)
    }

    func testExternalExtensionDefaultsToDisabled() {
        let store = NativExtensionStateStore(defaults: defaults)

        XCTAssertEqual(store.state(for: makeManifest(included: false)), .disabled)
    }

    func testIncludedExtensionCanDefaultToDisabled() {
        let store = NativExtensionStateStore(defaults: defaults)

        XCTAssertEqual(
            store.state(for: makeManifest(included: true, enabledByDefault: false)),
            .disabled
        )
    }

    func testRemovedTombstoneSurvivesStoreRecreation() {
        let key = "state.\(UUID().uuidString)"
        let manifest = makeManifest(included: true)
        let firstStore = NativExtensionStateStore(defaults: defaults, key: key)
        firstStore.set(.removed, for: manifest.id)

        let restoredStore = NativExtensionStateStore(defaults: defaults, key: key)

        XCTAssertEqual(restoredStore.state(for: manifest), .removed)
    }

    func testClearingStateRestoresDefault() {
        let manifest = makeManifest(included: true)
        let store = NativExtensionStateStore(defaults: defaults)
        store.set(.disabled, for: manifest.id)

        store.clear(extensionID: manifest.id)

        XCTAssertEqual(store.state(for: manifest), .enabled)
    }

    private func makeManifest(
        included: Bool,
        enabledByDefault: Bool? = nil
    ) -> NativExtensionManifest {
        NativExtensionManifest(
            id: "com.example.extension",
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "Example",
            summary: "Example extension",
            developer: "Example",
            systemImage: "puzzlepiece.extension",
            included: included,
            enabledByDefault: enabledByDefault,
            runtime: .extensionFoundation,
            runtimeBundleIdentifier: "com.example.extension.runtime"
        )
    }
}

final class NativDeclarativeManifestTests: XCTestCase {
    /// The vocabulary the marketplace validates against, kept here verbatim.
    /// `NativExtensionPermission` is a raw-value enum with no unknown-case
    /// fallback, so a permission the catalog allows but Nativ does not know
    /// fails the whole manifest decode and the package cannot even be listed.
    /// Mirror of `PERMISSIONS` in Marvis-Labs/nativ-extensions scripts/validate.py.
    private let catalogPermissions: Set<String> = [
        "accessibility.readSelection",
        "accessibility.insertText",
        "clipboard.read",
        "clipboard.write",
        "screen.capture",
        "file.save",
        "microphone",
        "audio.systemCapture",
        "overlay",
        "notifications",
        "storage.namespaced",
        "models.language",
        "models.vision",
        "models.imageGeneration",
        "models.imageEditing",
        "models.speechToText",
        "models.textToSpeech",
        "models.embedding",
    ]

    private func manifestJSON(
        runtime: String = "declarative",
        permissions: [String] = ["accessibility.readSelection", "models.language"],
        extra: [String: Any] = ["workflow": "Workflow.json"]
    ) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": "com.example.rewrite",
            "version": "1.0.0",
            "minimumNativVersion": "0.1.0",
            "displayName": "Rewrite",
            "summary": "Rewrites the selection.",
            "developer": "Example",
            "systemImage": "wand.and.sparkles",
            "included": false,
            "runtime": runtime,
            "permissions": permissions,
        ]
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testEveryCatalogPermissionIsKnownToNativ() {
        let known = Set(NativExtensionPermission.allCases.map(\.rawValue))
        XCTAssertEqual(
            catalogPermissions.subtracting(known),
            [],
            "The marketplace allows permissions Nativ cannot decode"
        )
        XCTAssertEqual(
            known.subtracting(catalogPermissions),
            [],
            "Nativ knows permissions the marketplace will not accept"
        )
    }

    func testDeclarativeManifestDecodesWithTheFullVocabulary() throws {
        let data = try manifestJSON(permissions: catalogPermissions.sorted())
        let manifest = try JSONDecoder().decode(NativExtensionManifest.self, from: data)

        XCTAssertEqual(manifest.runtime, .declarative)
        XCTAssertEqual(manifest.workflow, NativExtensionManifest.workflowDocumentName)
        XCTAssertEqual(Set(manifest.permissions.map(\.rawValue)), catalogPermissions)
        XCTAssertNoThrow(
            try NativExtensionManifestValidator.validate(manifest, hostVersion: "1.0.0")
        )
    }

    func testDeclarativeManifestWithoutAWorkflowIsRejected() throws {
        let data = try manifestJSON(extra: [:])
        let manifest = try JSONDecoder().decode(NativExtensionManifest.self, from: data)

        XCTAssertThrowsError(
            try NativExtensionManifestValidator.validate(manifest, hostVersion: "1.0.0")
        ) { error in
            XCTAssertEqual(error as? NativExtensionManifestError, .missingWorkflow)
        }
    }

    func testDeclarativeManifestCannotClaimAnOutOfProcessRuntime() throws {
        let data = try manifestJSON(
            extra: [
                "workflow": "Workflow.json",
                "runtimeBundleIdentifier": "com.example.rewrite.runtime",
            ]
        )
        let manifest = try JSONDecoder().decode(NativExtensionManifest.self, from: data)

        XCTAssertThrowsError(
            try NativExtensionManifestValidator.validate(manifest, hostVersion: "1.0.0")
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionManifestError,
                .unexpectedRuntimeBundleIdentifier
            )
        }
    }

    func testExtensionFoundationManifestIsUnaffected() throws {
        let data = try manifestJSON(
            runtime: "extensionFoundation",
            permissions: ["microphone"],
            extra: ["runtimeBundleIdentifier": "com.example.rewrite.runtime"]
        )
        let manifest = try JSONDecoder().decode(NativExtensionManifest.self, from: data)

        XCTAssertNil(manifest.workflow)
        XCTAssertNoThrow(
            try NativExtensionManifestValidator.validate(manifest, hostVersion: "1.0.0")
        )
    }
}
