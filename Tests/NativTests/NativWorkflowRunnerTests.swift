import Foundation
import NativExtensionSDK
import XCTest

/// Records what each stubbed service was asked to do, so a test can assert a
/// service was *not* reached as easily as it can assert a result.
private final class ServiceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _selectionReads = 0
    private var _modelPrompts: [String] = []
    private var _replaced: [String] = []

    var selectionReads: Int { lock.withLock { _selectionReads } }
    var modelPrompts: [String] { lock.withLock { _modelPrompts } }
    var replaced: [String] { lock.withLock { _replaced } }

    func recordSelectionRead() { lock.withLock { _selectionReads += 1 } }
    func recordPrompt(_ value: String) { lock.withLock { _modelPrompts.append(value) } }
    func recordReplacement(_ value: String) { lock.withLock { _replaced.append(value) } }
}

final class NativWorkflowRunnerTests: XCTestCase {
    private let extensionID = "com.example.rewrite"
    private var commandID: String { "\(extensionID).improve" }

    private func services(
        log: ServiceLog,
        selection: String? = "rough draft",
        modelResponse: String = "polished draft",
        substituted: String? = nil,
        replaceSucceeds: Bool = true
    ) -> NativWorkflowServices {
        NativWorkflowServices(
            readSelection: {
                log.recordSelectionRead()
                return selection.map { NativTextSelection(text: $0) }
            },
            replaceSelection: { text, _ in
                log.recordReplacement(text)
                return replaceSucceeds
            },
            invokeModel: { request in
                log.recordPrompt(request.prompt)
                return NativWorkflowModelResponse(
                    text: modelResponse,
                    substitutedModel: substituted
                )
            }
        )
    }

    private func context(
        log: ServiceLog,
        granted: Set<NativExtensionPermission> = [
            .readSelection, .accessibilityInsertText, .modelsLanguage,
        ],
        selection: String? = "rough draft",
        modelResponse: String = "polished draft",
        substituted: String? = nil,
        replaceSucceeds: Bool = true
    ) -> NativWorkflowRunContext {
        NativWorkflowRunContext(
            extensionID: extensionID,
            grantedPermissions: granted,
            services: services(
                log: log,
                selection: selection,
                modelResponse: modelResponse,
                substituted: substituted,
                replaceSucceeds: replaceSucceeds
            )
        )
    }

    private func rewriteWorkflow() -> NativExtensionWorkflow {
        NativExtensionWorkflow(
            triggers: [.init(id: "improve", type: .command, commandID: commandID)],
            steps: [
                .init(id: "selection", type: "text.readSelection"),
                .init(
                    id: "rewrite",
                    type: "model.invoke",
                    task: "language",
                    model: "automatic",
                    inputs: ["prompt": .text("Improve: {{selection.text}}")]
                ),
                .init(
                    id: "apply",
                    type: "text.replaceSelection",
                    inputs: ["text": .text("{{rewrite.text}}")]
                ),
            ]
        )
    }

    // MARK: - Acceptance

    /// The whole point of the slice: a declarative extension runs end to end
    /// with no server, no model, and no accessibility grant.
    func testRewriteWorkflowRunsEndToEnd() async throws {
        let log = ServiceLog()

        let summary = try await NativWorkflowRunner.run(
            rewriteWorkflow(),
            commandID: commandID,
            context: context(log: log)
        )

        XCTAssertEqual(summary.stepsRun, 3)
        XCTAssertEqual(summary.extensionID, extensionID)
        XCTAssertEqual(log.selectionReads, 1)
        XCTAssertEqual(log.modelPrompts, ["Improve: rough draft"])
        XCTAssertEqual(log.replaced, ["polished draft"])
    }

    func testSubstitutedModelIsReported() async throws {
        let log = ServiceLog()

        let summary = try await NativWorkflowRunner.run(
            rewriteWorkflow(),
            commandID: commandID,
            context: context(log: log, substituted: "org/author-choice")
        )

        XCTAssertEqual(summary.substitutedModel, "org/author-choice")
    }

    // MARK: - Permission enforcement replaces the broker

    /// A missing grant must stop the step *before* its service is reached, not
    /// after. Asserting the stub was never called is the point of the test.
    func testMissingPermissionThrowsBeforeTheServiceIsCalled() async {
        let log = ServiceLog()

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                rewriteWorkflow(),
                commandID: commandID,
                context: context(log: log, granted: [.accessibilityInsertText, .modelsLanguage])
            )
        ) { error in
            XCTAssertEqual(
                error as? NativWorkflowRunError,
                .permissionNotGranted(step: "selection", permission: .readSelection)
            )
        }
        XCTAssertEqual(log.selectionReads, 0, "the service ran despite a missing grant")
    }

    func testRevokedModelPermissionStopsBeforeTheModelIsCalled() async {
        let log = ServiceLog()

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                rewriteWorkflow(),
                commandID: commandID,
                context: context(log: log, granted: [.readSelection, .accessibilityInsertText])
            )
        ) { error in
            XCTAssertEqual(
                error as? NativWorkflowRunError,
                .permissionNotGranted(step: "rewrite", permission: .modelsLanguage)
            )
        }
        XCTAssertEqual(log.selectionReads, 1)
        XCTAssertTrue(log.modelPrompts.isEmpty, "the model ran despite a missing grant")
    }

    // MARK: - Failure paths

    func testNothingSelectedStopsTheRun() async {
        let log = ServiceLog()

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                rewriteWorkflow(),
                commandID: commandID,
                context: context(log: log, selection: nil)
            )
        ) { error in
            XCTAssertEqual(error as? NativWorkflowRunError, .nothingSelected)
        }
        XCTAssertTrue(log.modelPrompts.isEmpty)
    }

    func testAFailedReplacementIsReported() async {
        let log = ServiceLog()

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                rewriteWorkflow(),
                commandID: commandID,
                context: context(log: log, replaceSucceeds: false)
            )
        ) { error in
            XCTAssertEqual(error as? NativWorkflowRunError, .replaceFailed)
        }
    }

    func testAnUnimplementedOperationIsRefusedAtRunTime() async {
        let log = ServiceLog()
        let workflow = NativExtensionWorkflow(
            triggers: [.init(id: "t", type: .command, commandID: commandID)],
            steps: [.init(id: "shot", type: "screen.capture")]
        )

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                workflow,
                commandID: commandID,
                context: context(log: log, granted: [.screenCapture])
            )
        ) { error in
            XCTAssertEqual(
                error as? NativWorkflowRunError,
                .operationUnavailable(step: "shot", operation: "screen.capture")
            )
        }
    }

    func testACommandWithNoTriggerDoesNotRun() async {
        let log = ServiceLog()

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                rewriteWorkflow(),
                commandID: "\(extensionID).other",
                context: context(log: log)
            )
        ) { error in
            XCTAssertEqual(
                error as? NativWorkflowRunError,
                .noTriggerForCommand("\(extensionID).other")
            )
        }
        XCTAssertEqual(log.selectionReads, 0)
    }

    func testMissingInputIsNamed() async {
        let log = ServiceLog()
        let workflow = NativExtensionWorkflow(
            triggers: [.init(id: "t", type: .command, commandID: commandID)],
            steps: [
                .init(id: "selection", type: "text.readSelection"),
                .init(id: "rewrite", type: "model.invoke", task: "language"),
            ]
        )

        await XCTAssertThrowsErrorAsync(
            try await NativWorkflowRunner.run(
                workflow,
                commandID: commandID,
                context: context(log: log)
            )
        ) { error in
            XCTAssertEqual(
                error as? NativWorkflowRunError,
                .missingInput(step: "rewrite", name: "prompt")
            )
        }
    }

    // MARK: - Cancellation

    /// Disabling or removing an extension cancels its run. The check has to
    /// land between steps, so a cancelled workflow must not reach the model
    /// after the selection has already been read.
    func testCancellationStopsBeforeTheNextStep() async {
        let log = ServiceLog()
        let gate = RunGate()
        var stubbed = services(log: log)
        stubbed.readSelection = {
            log.recordSelectionRead()
            await gate.signalEnteredAndWait()
            return NativTextSelection(text: "rough draft")
        }
        let runContext = NativWorkflowRunContext(
            extensionID: extensionID,
            grantedPermissions: [.readSelection, .accessibilityInsertText, .modelsLanguage],
            services: stubbed
        )

        let workflow = rewriteWorkflow()
        let identifier = commandID
        let task = Task {
            try await NativWorkflowRunner.run(
                workflow,
                commandID: identifier,
                context: runContext
            )
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("The run completed despite being cancelled")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(log.selectionReads, 1)
        XCTAssertTrue(log.modelPrompts.isEmpty, "the model ran after cancellation")
        XCTAssertTrue(log.replaced.isEmpty)
    }

    // MARK: - Bindings

    func testSubstitutionFillsEveryBinding() {
        let outputs: [String: NativWorkflowStepOutput] = [
            "a": ["text": .text("one")],
            "b": ["other": .text("two")],
        ]

        XCTAssertEqual(
            NativWorkflowRunner.substitute("{{a.text}} and {{b.other}}", outputs: outputs),
            "one and two"
        )
        XCTAssertEqual(
            NativWorkflowRunner.substitute("{{a}}", outputs: outputs),
            "one",
            "a bare step reference should read its text output"
        )
        XCTAssertEqual(
            NativWorkflowRunner.substitute("{{missing.text}}", outputs: outputs),
            "",
            "an unresolvable binding must not leave its template in the prompt"
        )
    }
}

/// Lets a test pause inside a stubbed service, cancel the run, and then let
/// the service finish — so the cancellation check is exercised deterministically
/// rather than raced.
private actor RunGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signalEnteredAndWait() async {
        hasEntered = true
        entered?.resume()
        entered = nil
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
