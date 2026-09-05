import Foundation
import NativExtensionSDK
import XCTest

final class NativExtensionWorkflowTests: XCTestCase {
    private let extensionID = "com.example.rewrite"

    private func manifest(
        permissions: [NativExtensionPermission] = [
            .readSelection, .accessibilityInsertText, .modelsLanguage,
        ],
        commands: [String] = ["com.example.rewrite.improve"]
    ) -> NativExtensionManifest {
        NativExtensionManifest(
            id: extensionID,
            version: "1.0.0",
            minimumNativVersion: "0.1.0",
            displayName: "Rewrite",
            summary: "Rewrites the selection.",
            developer: "Example",
            systemImage: "wand.and.sparkles",
            included: false,
            runtime: .declarative,
            workflow: NativExtensionManifest.workflowDocumentName,
            contributions: .init(
                commands: commands.map { .init(id: $0, title: "Improve") }
            ),
            permissions: permissions
        )
    }

    private func workflow(
        schemaVersion: Int = NativExtensionWorkflow.currentSchemaVersion,
        triggers: [NativWorkflowTrigger]? = nil,
        steps: [NativWorkflowStep]? = nil
    ) -> NativExtensionWorkflow {
        NativExtensionWorkflow(
            schemaVersion: schemaVersion,
            triggers: triggers ?? [
                .init(id: "improve", type: .command, commandID: "com.example.rewrite.improve")
            ],
            steps: steps ?? [
                .init(id: "selection", type: "text.readSelection"),
                .init(
                    id: "rewrite",
                    type: "model.invoke",
                    task: "language",
                    inputs: ["prompt": .text("Improve {{selection.text}}")]
                ),
                .init(
                    id: "apply",
                    type: "text.replaceSelection",
                    inputs: ["text": .text("{{rewrite.text}}")]
                ),
            ]
        )
    }

    private func expect(
        _ expected: NativExtensionWorkflowError,
        _ workflow: NativExtensionWorkflow,
        _ manifest: NativExtensionManifest,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NativExtensionWorkflowValidator.validate(workflow, manifest: manifest),
            line: line
        ) { error in
            XCTAssertEqual(error as? NativExtensionWorkflowError, expected, line: line)
        }
    }

    // MARK: - The security rules

    func testRewriteWorkflowIsAccepted() throws {
        XCTAssertNoThrow(
            try NativExtensionWorkflowValidator.validate(workflow(), manifest: manifest())
        )
    }

    func testStepUsingAnUndeclaredPermissionIsRejected() {
        expect(
            .undeclaredPermission(
                step: "selection",
                operation: "text.readSelection",
                permission: .readSelection
            ),
            workflow(),
            manifest(permissions: [.accessibilityInsertText, .modelsLanguage])
        )
    }

    func testModelTaskWithoutItsPermissionIsRejected() {
        expect(
            .undeclaredPermission(
                step: "rewrite",
                operation: "model.invoke",
                permission: .modelsLanguage
            ),
            workflow(),
            manifest(permissions: [.readSelection, .accessibilityInsertText])
        )
    }

    func testReferenceToALaterStepIsRejected() {
        expect(
            .unresolvedReference(step: "apply", reference: "rewrite.text"),
            workflow(steps: [
                .init(id: "selection", type: "text.readSelection"),
                .init(
                    id: "apply",
                    type: "text.replaceSelection",
                    inputs: ["text": .text("{{rewrite.text}}")]
                ),
            ]),
            manifest()
        )
    }

    func testSelfReferenceIsRejected() {
        expect(
            .unresolvedReference(step: "selection", reference: "selection.text"),
            workflow(steps: [
                .init(
                    id: "selection",
                    type: "text.readSelection",
                    inputs: ["seed": .text("{{selection.text}}")]
                )
            ]),
            manifest()
        )
    }

    func testTriggerForAnUndeclaredCommandIsRejected() {
        expect(
            .undeclaredCommand(trigger: "improve", commandID: "com.example.rewrite.improve"),
            workflow(),
            manifest(commands: ["com.example.rewrite.other"])
        )
    }

    // MARK: - Shape

    func testUnknownOperationNamesTheOperation() {
        expect(
            .unknownOperation(step: "a", operation: "shell.run"),
            workflow(steps: [.init(id: "a", type: "shell.run")]),
            manifest()
        )
    }

    func testOperationWithoutAnImplementationIsRefusedAtInstall() {
        expect(
            .unimplementedOperation(step: "a", operation: "screen.capture"),
            workflow(steps: [.init(id: "a", type: "screen.capture")]),
            manifest(permissions: [.screenCapture])
        )
    }

    func testUnknownModelTaskIsRejected() {
        expect(
            .unknownModelTask(step: "a", task: "telepathy"),
            workflow(steps: [.init(id: "a", type: "model.invoke", task: "telepathy")]),
            manifest()
        )
    }

    func testDuplicateStepIsRejected() {
        expect(
            .duplicateStep("selection"),
            workflow(steps: [
                .init(id: "selection", type: "text.readSelection"),
                .init(id: "selection", type: "text.readSelection"),
            ]),
            manifest()
        )
    }

    func testWrongSchemaVersionIsRejected() {
        expect(.unsupportedSchema(1), workflow(schemaVersion: 1), manifest())
    }

    func testEmptyTriggersAndStepsAreRejected() {
        expect(.noTriggers, workflow(triggers: []), manifest())
        expect(.noSteps, workflow(steps: []), manifest())
    }

    // MARK: - Model and references

    func testWorkflowDecodesFromTheDocumentTheMarketplaceShips() throws {
        let json = """
        {
          "schemaVersion": 2,
          "triggers": [
            { "id": "improve", "type": "command", "commandID": "com.example.rewrite.improve" }
          ],
          "steps": [
            { "id": "selection", "type": "text.readSelection" },
            {
              "id": "rewrite", "type": "model.invoke", "task": "language",
              "model": "automatic",
              "inputs": { "prompt": "Improve {{selection.text}}" },
              "maxTokens": 2048, "temperature": 0.2
            },
            {
              "id": "apply", "type": "text.replaceSelection",
              "inputs": { "text": "{{rewrite.text}}" }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(
            NativExtensionWorkflow.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.steps.count, 3)
        XCTAssertEqual(decoded.steps[1].operation, .invokeModel)
        XCTAssertEqual(decoded.steps[1].modelTask, .language)
        XCTAssertEqual(decoded.steps[1].maxTokens, 2048)
        XCTAssertEqual(decoded.trigger(forCommand: "com.example.rewrite.improve")?.id, "improve")
        XCTAssertNoThrow(
            try NativExtensionWorkflowValidator.validate(decoded, manifest: manifest())
        )
    }

    func testReferenceParsing() {
        let found = NativWorkflowReference.references(in: "a {{one.text}} b {{two}} c")
        XCTAssertEqual(found.map(\.step), ["one", "two"])
        XCTAssertEqual(found.map(\.output), ["text", nil])
        XCTAssertTrue(NativWorkflowReference.references(in: "no bindings").isEmpty)
    }

    func testBinaryValuesCannotBeWrittenIntoAWorkflow() {
        XCTAssertThrowsError(
            try JSONEncoder().encode(NativWorkflowValue.data(Data([0x1]), uti: "public.png"))
        )
        XCTAssertNoThrow(try JSONEncoder().encode(NativWorkflowValue.text("fine")))
    }

    func testEveryOperationDeclaresItsPermission() {
        for operation in NativWorkflowOperation.allCases where operation != .invokeModel {
            XCTAssertNotNil(
                operation.requiredPermission,
                "\(operation.rawValue) does not say what it costs the user"
            )
        }
        XCTAssertNil(NativWorkflowOperation.invokeModel.requiredPermission)
    }
}
