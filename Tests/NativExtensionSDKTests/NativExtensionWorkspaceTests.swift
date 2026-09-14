import Foundation
import NativExtensionSDK
import XCTest

final class NativExtensionWorkspaceTests: XCTestCase {
    private var example: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/ExtensionWorkspace/com.example.workspace.nativextension")
    }

    private func fixture() throws -> (NativExtensionManifest, NativExtensionDashboard, NativExtensionWorkflow) {
        let decoder = JSONDecoder()
        return (
            try decoder.decode(NativExtensionManifest.self, from: Data(contentsOf: example.appendingPathComponent("Manifest.json"))),
            try decoder.decode(NativExtensionDashboard.self, from: Data(contentsOf: example.appendingPathComponent("Dashboard.json"))),
            try decoder.decode(NativExtensionWorkflow.self, from: Data(contentsOf: example.appendingPathComponent("Workflow.json")))
        )
    }

    private func mutatedDashboard(_ mutate: (inout [String: Any]) -> Void) throws -> NativExtensionDashboard {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: example.appendingPathComponent("Dashboard.json"))) as? [String: Any])
        mutate(&json)
        return try JSONDecoder().decode(NativExtensionDashboard.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testWorkspaceInstallsAndReloadsBothDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = NativExtensionPackageInstaller(fileManager: .default, extensionsDirectory: root, hostVersion: "0.3.7")
        let result = try installer.install(from: example, reservedIdentifiers: [])
        XCTAssertTrue(result.requiresReconsent)
        let loaded = try XCTUnwrap(installer.loadInstalledPackages(reservedIdentifiers: []).manifests[result.manifest.id])
        XCTAssertEqual(loaded.dashboard?.tabs.count, 2)
        XCTAssertEqual(loaded.workflow?.steps(forCommand: "com.example.workspace.clear").map(\.id), ["clear"])
    }

    func testLinkedDashboardIsRejectedBeforeInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("workspace.nativextension")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: example, to: package)
        let dashboardURL = package.appendingPathComponent("Dashboard.json")
        try FileManager.default.removeItem(at: dashboardURL)
        try FileManager.default.createSymbolicLink(at: dashboardURL, withDestinationURL: example.appendingPathComponent("Dashboard.json"))
        let installer = NativExtensionPackageInstaller(fileManager: .default, extensionsDirectory: root.appendingPathComponent("Installed"), hostVersion: "0.3.7")
        XCTAssertThrowsError(try installer.validate(packageAt: package))
    }

    func testReadOnlyWorkspaceNeedsNoWorkflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("workspace.nativextension")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: example, to: package)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("Manifest.json"))) as? [String: Any])
        manifest.removeValue(forKey: "workflow")
        var contributions = try XCTUnwrap(manifest["contributions"] as? [String: Any])
        contributions["commands"] = []
        manifest["contributions"] = contributions
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("Manifest.json"))
        let dashboard: [String: Any] = ["schemaVersion": 1, "title": "Read only", "storage": [:], "tabs": [["id": "home", "title": "Home", "sections": [["id": "about", "title": "About", "components": [["id": "text", "type": "text", "title": "Info", "text": "A native page"]]]]]]]
        try JSONSerialization.data(withJSONObject: dashboard).write(to: package.appendingPathComponent("Dashboard.json"))
        try FileManager.default.removeItem(at: package.appendingPathComponent("Workflow.json"))
        let installer = NativExtensionPackageInstaller(fileManager: .default, extensionsDirectory: root.appendingPathComponent("Installed"), hostVersion: "0.3.7")
        XCTAssertNoThrow(try installer.validate(packageAt: package))
    }

    func testDashboardRejectsUnknownFieldsComponentsAndDuplicateIdentity() throws {
        let (manifest, _, _) = try fixture()
        XCTAssertThrowsError(try mutatedDashboard { $0["script"] = "run()" })
        let duplicate = try mutatedDashboard { json in
            var tabs = json["tabs"] as! [[String: Any]]
            tabs[1]["id"] = tabs[0]["id"]
            json["tabs"] = tabs
        }
        XCTAssertThrowsError(try NativExtensionDashboardValidator.validate(duplicate, manifest: manifest))
        for field in ["missing", "tempo"] {
            let wrongType = try mutatedDashboard { json in
                var tabs = json["tabs"] as! [[String: Any]]
                var sections = tabs[1]["sections"] as! [[String: Any]]
                var components = sections[0]["components"] as! [[String: Any]]
                components[1]["storageKey"] = field
                sections[0]["components"] = components
                tabs[1]["sections"] = sections
                json["tabs"] = tabs
            }
            XCTAssertThrowsError(try NativExtensionDashboardValidator.validate(wrongType, manifest: manifest))
        }
    }

    func testUndeclaredCommandAndMissingStorageConsentAreRejected() throws {
        let (manifest, _, _) = try fixture()
        let dashboard = try mutatedDashboard { json in
            var tabs = json["tabs"] as! [[String: Any]]
            var sections = tabs[0]["sections"] as! [[String: Any]]
            var components = sections[0]["components"] as! [[String: Any]]
            components[1]["commandID"] = "com.other.command"
            sections[0]["components"] = components
            tabs[0]["sections"] = sections
            json["tabs"] = tabs
        }
        XCTAssertThrowsError(try NativExtensionDashboardValidator.validate(dashboard, manifest: manifest))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        raw["permissions"] = []
        let noConsent = try JSONDecoder().decode(NativExtensionManifest.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try NativExtensionDashboardValidator.validate(try fixture().1, manifest: noConsent))
    }

    func testStoragePersistsAndSeparatesExtensions() throws {
        let fields = try fixture().1.storage
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = NativExtensionWorkspaceStorage(directory: root.appendingPathComponent("one"), fields: fields)
        let two = NativExtensionWorkspaceStorage(directory: root.appendingPathComponent("two"), fields: fields)
        var values = try one.load()
        values["draft"] = .text("{{private.value}} stays literal")
        values["tempo"] = .number(96)
        try one.save(values)
        XCTAssertEqual(try one.load(), values)
        XCTAssertEqual(try two.load()["tempo"], .number(120))
        values["../escape"] = .text("bad")
        XCTAssertThrowsError(try one.save(values))
        values.removeValue(forKey: "../escape")
        values["tempo"] = .text("wrong type")
        XCTAssertThrowsError(try one.save(values))
        values["tempo"] = .number(120)
        values["draft"] = .text(String(repeating: "x", count: 65_537))
        XCTAssertThrowsError(try one.save(values))
    }

    func testCorruptStateIsNotSilentlyReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json")
        try Data("broken".utf8).write(to: url)
        let store = NativExtensionWorkspaceStorage(directory: root, fields: try fixture().1.storage)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }

    func testWorkflowRejectsWrongTypesKeysAndMissingCommandDependencies() throws {
        let (manifest, dashboard, workflow) = try fixture()
        for inputs: [String: NativWorkflowValue] in [
            ["key": .text("tempo"), "value": .text("{{read.value}}")],
            ["key": .text("../outside"), "value": .text("text")],
            ["key": .text("saved"), "value": .text("{{malformed")],
        ] {
            let bad = NativExtensionWorkflow(triggers: workflow.triggers, steps: [workflow.steps[0], .init(id: "save", type: "storage.write", inputs: inputs), workflow.steps[2]])
            XCTAssertThrowsError(try NativExtensionWorkflowValidator.validate(bad, manifest: manifest, dashboard: dashboard))
        }
        let badRoute = NativExtensionWorkflow(triggers: [
            .init(id: "save", type: .command, commandID: "com.example.workspace.save", steps: ["save"]),
            workflow.triggers[1],
        ], steps: workflow.steps)
        XCTAssertThrowsError(try NativExtensionWorkflowValidator.validate(badRoute, manifest: manifest, dashboard: dashboard))
        XCTAssertNoThrow(try NativExtensionWorkflowValidator.validate(workflow, manifest: manifest, dashboard: dashboard))
    }
}
