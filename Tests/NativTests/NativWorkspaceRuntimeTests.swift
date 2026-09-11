import Foundation
import NativExtensionSDK
import XCTest

@MainActor
final class NativWorkspaceRuntimeTests: XCTestCase {
    private func fixture() throws -> (NativExtensionManifest, NativExtensionDashboard, NativExtensionWorkflow) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/ExtensionWorkspace/com.example.workspace.nativextension")
        let decoder = JSONDecoder()
        return (
            try decoder.decode(NativExtensionManifest.self, from: Data(contentsOf: root.appendingPathComponent("Manifest.json"))),
            try decoder.decode(NativExtensionDashboard.self, from: Data(contentsOf: root.appendingPathComponent("Dashboard.json"))),
            try decoder.decode(NativExtensionWorkflow.self, from: Data(contentsOf: root.appendingPathComponent("Workflow.json")))
        )
    }

    private func waitUntilIdle(_ runtime: NativDeclarativeExtension) async {
        for _ in 0..<10_000 {
            if !runtime.isRunning { return }
            await Task.yield()
        }
        XCTFail("Workspace command did not finish")
    }

    func testCommandsUseDistinctRoutesAndPersistWithoutASelection() async throws {
        let (manifest, dashboard, workflow) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativDeclarativeExtension(
            manifest: manifest, workflow: workflow, dashboard: dashboard, storageDirectory: root,
            grantedPermissions: [.namespacedStorage], services: {
                NativWorkflowServices(readSelection: { XCTFail("Unexpected selection read"); return nil },
                    replaceSelection: { _, _ in XCTFail("Unexpected insertion"); return false },
                    invokeModel: { _ in XCTFail("Unexpected model request"); return .init(text: "") })
            }, onFailure: { XCTFail($0) }
        )
        runtime.activate()
        runtime.setValue(.text("Keep this note"), for: "draft")
        runtime.performCommand(id: "com.example.workspace.save")
        await waitUntilIdle(runtime)
        XCTAssertEqual(runtime.workspace?.values["saved"], .text("Keep this note"))
        XCTAssertEqual(runtime.completedSteps, 2)
        runtime.performCommand(id: "com.example.workspace.clear")
        await waitUntilIdle(runtime)
        XCTAssertEqual(runtime.workspace?.values["saved"], .text(""))
        XCTAssertEqual(runtime.workspace?.values["draft"], .text("Keep this note"))
        XCTAssertEqual(runtime.completedSteps, 1)
        runtime.deactivate()
        let restored = NativWorkspaceState(directory: root, fields: dashboard.storage)
        XCTAssertEqual(restored.values["draft"], .text("Keep this note"))
        runtime.performCommand(id: "com.example.workspace.save")
        XCTAssertFalse(runtime.isRunning)
    }

    func testCancellationPreventsLateModelResultFromWritingState() async throws {
        let (manifest, dashboard, _) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkspaceModelGate()
        let workflow = NativExtensionWorkflow(triggers: [
            .init(id: "save", type: .command, commandID: "com.example.workspace.save", steps: ["model", "save"]),
            .init(id: "clear", type: .command, commandID: "com.example.workspace.clear", steps: ["new"]),
        ], steps: [
            .init(id: "model", type: "model.invoke", task: "language", inputs: ["prompt": .text("test")]),
            .init(id: "save", type: "storage.write", inputs: ["key": .text("saved"), "value": .text("{{model.text}}")]),
            .init(id: "new", type: "storage.write", inputs: ["key": .text("saved"), "value": .text("new run")]),
        ])
        let runtime = NativDeclarativeExtension(
            manifest: manifest, workflow: workflow, dashboard: dashboard, storageDirectory: root,
            grantedPermissions: [.namespacedStorage, .modelsLanguage], services: {
                NativWorkflowServices(readSelection: { nil }, replaceSelection: { _, _ in false },
                    invokeModel: { _ in await gate.response() })
            }, onFailure: { XCTFail($0) }
        )
        runtime.activate()
        runtime.performCommand(id: "com.example.workspace.save")
        for _ in 0..<10_000 {
            if await gate.isWaiting { break }
            await Task.yield()
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        runtime.deactivate()
        runtime.activate()
        runtime.performCommand(id: "com.example.workspace.clear")
        await waitUntilIdle(runtime)
        await gate.finish()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(runtime.workspace?.values["saved"], .text("new run"))
        XCTAssertEqual(runtime.status, "Completed")
        XCTAssertFalse(runtime.isRunning)
    }

    func testPermissionRevocationCancelsRunAndControlsCannotWriteWhileDisabled() throws {
        let (manifest, dashboard, workflow) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativDeclarativeExtension(
            manifest: manifest, workflow: workflow, dashboard: dashboard, storageDirectory: root,
            grantedPermissions: [.namespacedStorage], services: {
                NativWorkflowServices(readSelection: { nil }, replaceSelection: { _, _ in false }, invokeModel: { _ in .init(text: "") })
            }, onFailure: { XCTFail($0) }
        )
        runtime.setValue(.text("disabled"), for: "draft")
        XCTAssertEqual(runtime.workspace?.values["draft"], .text(""))
        runtime.activate()
        runtime.performCommand(id: "com.example.workspace.save")
        runtime.updateGrantedPermissions([])
        XCTAssertFalse(runtime.isRunning)
        XCTAssertEqual(runtime.status, "Cancelled")
        runtime.setValue(.text("revoked"), for: "draft")
        XCTAssertEqual(runtime.workspace?.values["draft"], .text(""))
    }

    func testBindingValuesAreNeverReinterpretedAsTemplates() {
        let output: [String: NativWorkflowStepOutput] = [
            "input": ["text": .text("{{secret.text}}")],
            "secret": ["text": .text("must not leak")],
            "tempo": ["value": .number(120)],
        ]
        XCTAssertEqual(NativWorkflowRunner.substitute("{{input.text}} and {{secret.text}}", outputs: output), "{{secret.text}} and must not leak")
        XCTAssertEqual(NativWorkflowRunner.resolvedValue(.text("{{tempo.value}}"), outputs: output), .number(120))
    }
}

private actor WorkspaceModelGate {
    private var continuation: CheckedContinuation<NativWorkflowModelResponse, Never>?
    var isWaiting: Bool { continuation != nil }
    func response() async -> NativWorkflowModelResponse {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: .init(text: "late result"))
        continuation = nil
    }
}
