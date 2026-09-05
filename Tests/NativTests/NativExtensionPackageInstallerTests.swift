import Foundation
import NativExtensionSDK
import XCTest

final class NativExtensionPackageInstallerTests: XCTestCase {
    private var root: URL!
    private var extensionsDirectory: URL!
    private var installer: NativExtensionPackageInstaller!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        extensionsDirectory = root.appendingPathComponent("Extensions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionsDirectory,
            withIntermediateDirectories: true
        )
        installer = NativExtensionPackageInstaller(
            fileManager: .default,
            extensionsDirectory: extensionsDirectory,
            hostVersion: "1.0.0"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makePackage(
        id: String = "com.example.demo",
        version: String = "1.0.0",
        minimumNativVersion: String = "1.0.0",
        included: Bool = false,
        runtime: String = "extensionFoundation",
        permissions: [String] = ["overlay"]
    ) throws -> URL {
        let packageURL = root.appendingPathComponent(
            "\(UUID().uuidString).nativextension",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "version": version,
            "minimumNativVersion": minimumNativVersion,
            "displayName": "Demo",
            "summary": "A demo extension.",
            "developer": "Example",
            "systemImage": "sparkles",
            "included": included,
            "runtime": runtime,
            "runtimeBundleIdentifier": "com.example.demo.runtime",
            "permissions": permissions,
        ]
        try write(manifest, to: packageURL.appendingPathComponent("Manifest.json"))
        return packageURL
    }

    @discardableResult
    private func install(
        _ packageURL: URL,
        reserved: Set<String> = []
    ) throws -> NativExtensionPackageInstaller.InstallResult {
        try installer.install(from: packageURL, reservedIdentifiers: reserved)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func installedManifest() throws -> NativExtensionManifest {
        try installer.loadManifest(at: installer.packageURL(for: "com.example.demo"))
    }

    // MARK: - Installing

    func testInstallCopiesPackageUnderItsIdentifier() throws {
        let source = try makePackage()

        let result = try install(source)

        XCTAssertEqual(result.manifest.id, "com.example.demo")
        XCTAssertNil(result.replaced)
        XCTAssertTrue(result.requiresReconsent)
        XCTAssertEqual(try installedManifest().version, "1.0.0")
    }

    func testInstallRejectsAFileThatIsNotAPackageDirectory() throws {
        let plainFile = root.appendingPathComponent("NotAPackage.nativextension")
        try Data("nope".utf8).write(to: plainFile)

        XCTAssertThrowsError(
            try install(plainFile)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionPackageError,
                .packageMustBeDirectory
            )
        }
    }

    func testInstallRejectsAnIdentifierShippedWithNativ() throws {
        let source = try makePackage(id: "com.nativ.voice-dictation")

        XCTAssertThrowsError(
            try install(source, reserved: ["com.nativ.voice-dictation"])
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionPackageError,
                .duplicateIdentifier("com.nativ.voice-dictation")
            )
        }
    }

    func testInstallRejectsARuntimeAnInstalledPackageCannotUse() throws {
        let source = try makePackage(runtime: "builtIn")

        XCTAssertThrowsError(try install(source)) { error in
            XCTAssertEqual(
                error as? NativExtensionPackageError,
                .unsupportedExternalRuntime
            )
        }
    }

    func testInstallRejectsAnExternalPackageClaimingToBeIncluded() throws {
        let source = try makePackage(included: true)

        XCTAssertThrowsError(
            try install(source)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionPackageError,
                .externalPackageClaimsIncluded
            )
        }
    }

    func testInstallRejectsAHostVersionItRequiresButDoesNotHave() throws {
        let source = try makePackage(minimumNativVersion: "2.0.0")

        XCTAssertThrowsError(
            try install(source)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionManifestError,
                .incompatibleHost(required: "2.0.0", current: "1.0.0")
            )
        }
    }

    // MARK: - Updating

    func testUpdateToANewerVersionReplacesTheInstalledPackage() throws {
        try install(makePackage(version: "1.0.0"))

        let result = try install(makePackage(version: "1.2.0"))

        XCTAssertEqual(result.replaced?.version, "1.0.0")
        XCTAssertEqual(try installedManifest().version, "1.2.0")
    }

    func testUpdateKeepingTheSamePermissionsDoesNotRequireReconsent() throws {
        try install(makePackage(version: "1.0.0", permissions: ["overlay"]))

        let result = try install(
            makePackage(version: "1.1.0", permissions: ["overlay"])
        )

        XCTAssertFalse(result.requiresReconsent)
    }

    func testUpdateAskingForMorePermissionsRequiresReconsent() throws {
        try install(makePackage(version: "1.0.0", permissions: ["overlay"]))

        let result = try install(
            makePackage(version: "1.1.0", permissions: ["overlay", "microphone"])
        )

        XCTAssertTrue(result.requiresReconsent)
    }

    func testReinstallingTheSameVersionIsAllowed() throws {
        try install(makePackage(version: "1.0.0"))

        let result = try install(makePackage(version: "1.0.0"))

        XCTAssertEqual(result.replaced?.version, "1.0.0")
        XCTAssertEqual(try installedManifest().version, "1.0.0")
    }

    func testDowngradeIsRejectedAndLeavesTheInstalledVersionInPlace() throws {
        try install(makePackage(version: "2.0.0"))

        XCTAssertThrowsError(
            try install(makePackage(version: "1.0.0"))
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionPackageError,
                .olderVersionRejected(
                    identifier: "com.example.demo",
                    installed: "2.0.0",
                    candidate: "1.0.0"
                )
            )
        }
        XCTAssertEqual(try installedManifest().version, "2.0.0")
    }

    // MARK: - Loading

    func testLoadReportsAPackageItCannotReadInsteadOfDroppingIt() throws {
        let broken = extensionsDirectory
            .appendingPathComponent("broken.nativextension", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("Manifest.json"))

        let result = installer.loadInstalledPackages(reservedIdentifiers: [])

        XCTAssertTrue(result.manifests.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.packageName, "broken.nativextension")
    }

    func testLoadSkipsPackagesWhoseIdentifierIsReserved() throws {
        try install(makePackage())

        let result = installer.loadInstalledPackages(
            reservedIdentifiers: ["com.example.demo"]
        )

        XCTAssertTrue(result.manifests.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testLoadSweepsStagingDirectoriesLeftByAnInterruptedInstall() throws {
        let staging = extensionsDirectory.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        _ = installer.loadInstalledPackages(reservedIdentifiers: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: - Manifest authoring

    func testManifestOmittingOptionalStructureStillLoads() throws {
        let packageURL = root.appendingPathComponent("Minimal.nativextension", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try write(
            [
                "id": "com.example.minimal",
                "version": "1.0.0",
                "minimumNativVersion": "1.0.0",
                "displayName": "Minimal",
                "summary": "No contributions or permissions.",
                "developer": "Example",
                "systemImage": "sparkles",
                "runtime": "builtIn",
                "contributions": ["sidebar": []],
            ],
            to: packageURL.appendingPathComponent("Manifest.json")
        )

        let manifest = try installer.loadManifest(at: packageURL)

        XCTAssertEqual(manifest.schemaVersion, NativExtensionManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.extensionPoint, "com.nativ.extension")
        XCTAssertFalse(manifest.included)
        XCTAssertTrue(manifest.permissions.isEmpty)
        XCTAssertTrue(manifest.contributions.sidebar.isEmpty)
    }

    func testMissingRequiredFieldNamesTheFieldInTheError() throws {
        let packageURL = root.appendingPathComponent("Broken.nativextension", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try write(
            [
                "id": "com.example.broken",
                "version": "1.0.0",
                "minimumNativVersion": "1.0.0",
                "displayName": "Broken",
                "summary": "Missing developer.",
                "systemImage": "sparkles",
                "runtime": "builtIn",
            ],
            to: packageURL.appendingPathComponent("Manifest.json")
        )

        XCTAssertThrowsError(try installer.loadManifest(at: packageURL)) { error in
            let message = (error as? NativExtensionPackageError)?.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("developer"),
                "Expected the error to name the missing field, got: \(message)"
            )
        }
    }

    func testMissingManifestIsReportedDistinctly() throws {
        let packageURL = root.appendingPathComponent("Empty.nativextension", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try installer.loadManifest(at: packageURL)) { error in
            XCTAssertEqual(error as? NativExtensionPackageError, .missingManifest)
        }
    }

    // MARK: - Declarative packages

    @discardableResult
    private func makeDeclarativePackage(
        id: String = "com.example.rewrite",
        permissions: [String] = [
            "accessibility.readSelection", "accessibility.insertText", "models.language",
        ],
        workflow: [String: Any]? = nil,
        omitWorkflow: Bool = false
    ) throws -> URL {
        let packageURL = root.appendingPathComponent(
            "\(UUID().uuidString).nativextension",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try write(
            [
                "schemaVersion": 1,
                "id": id,
                "version": "1.0.0",
                "minimumNativVersion": "1.0.0",
                "displayName": "Rewrite",
                "summary": "Rewrites the selection.",
                "developer": "Example",
                "systemImage": "wand.and.sparkles",
                "included": false,
                "runtime": "declarative",
                "workflow": "Workflow.json",
                "contributions": [
                    "commands": [["id": "\(id).improve", "title": "Improve"]]
                ],
                "permissions": permissions,
            ],
            to: packageURL.appendingPathComponent("Manifest.json")
        )
        guard !omitWorkflow else { return packageURL }
        let document: [String: Any] = workflow ?? [
            "schemaVersion": 2,
            "triggers": [["id": "improve", "type": "command", "commandID": "\(id).improve"]],
            "steps": [
                ["id": "selection", "type": "text.readSelection"],
                [
                    "id": "rewrite", "type": "model.invoke", "task": "language",
                    "inputs": ["prompt": "Improve {{selection.text}}"],
                ],
                [
                    "id": "apply", "type": "text.replaceSelection",
                    "inputs": ["text": "{{rewrite.text}}"],
                ],
            ],
        ]
        try write(document, to: packageURL.appendingPathComponent("Workflow.json"))
        return packageURL
    }

    func testDeclarativePackageInstallsAndCarriesItsWorkflow() throws {
        let result = try install(makeDeclarativePackage())

        XCTAssertEqual(result.manifest.runtime, .declarative)
        let loaded = installer.loadInstalledPackages(reservedIdentifiers: [])
        let installed = try XCTUnwrap(loaded.manifests["com.example.rewrite"])
        XCTAssertEqual(installed.workflow?.steps.count, 3)
        XCTAssertTrue(loaded.issues.isEmpty)
    }

    func testDeclarativePackageWithoutAWorkflowDocumentIsRejected() throws {
        XCTAssertThrowsError(
            try install(makeDeclarativePackage(omitWorkflow: true))
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionPackageError,
                .missingWorkflowDocument
            )
        }
    }

    /// The install-time half of the permission rule: a package cannot ship a
    /// step it never asked permission for.
    func testDeclarativePackageUsingAnUndeclaredPermissionIsRejected() throws {
        XCTAssertThrowsError(
            try install(makeDeclarativePackage(permissions: ["accessibility.insertText"]))
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionWorkflowError,
                .undeclaredPermission(
                    step: "selection",
                    operation: "text.readSelection",
                    permission: .readSelection
                )
            )
        }
    }

    func testDeclarativePackageUsingAnUnimplementedOperationIsRejected() throws {
        XCTAssertThrowsError(
            try install(
                makeDeclarativePackage(
                    permissions: ["screen.capture"],
                    workflow: [
                        "schemaVersion": 2,
                        "triggers": [[
                            "id": "t", "type": "command",
                            "commandID": "com.example.rewrite.improve",
                        ]],
                        "steps": [["id": "a", "type": "screen.capture"]],
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionWorkflowError,
                .unimplementedOperation(step: "a", operation: "screen.capture")
            )
        }
    }

    func testMalformedWorkflowIsReportedAgainstTheWorkflowDocument() throws {
        let packageURL = try makeDeclarativePackage(omitWorkflow: true)
        try Data("{".utf8).write(to: packageURL.appendingPathComponent("Workflow.json"))

        XCTAssertThrowsError(try install(packageURL)) { error in
            let message = (error as? NativExtensionPackageError)?.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("Workflow.json"),
                "Expected the error to name the workflow document, got: \(message)"
            )
        }
    }

    // MARK: - Removing

    func testRemoveDeletesTheInstalledPackage() throws {
        try install(makePackage())
        let installedURL = installer.packageURL(for: "com.example.demo")

        try installer.removePackage(at: installedURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        XCTAssertTrue(
            installer.loadInstalledPackages(reservedIdentifiers: []).manifests.isEmpty
        )
    }
}
