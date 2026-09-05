import Foundation
import NativExtensionSDK

/// Executes a declarative workflow.
///
/// Stateless on purpose: every run's state is local, so there is no shared
/// mutable state to reason about and the whole thing can be driven from a test
/// with stubbed services.
enum NativWorkflowRunner {
    static func run(
        _ workflow: NativExtensionWorkflow,
        commandID: String,
        context: NativWorkflowRunContext
    ) async throws -> NativWorkflowRunSummary {
        guard workflow.trigger(forCommand: commandID) != nil else {
            throw NativWorkflowRunError.noTriggerForCommand(commandID)
        }

        var outputs: [String: NativWorkflowStepOutput] = [:]
        var selection: NativTextSelection?
        var substitutedModel: String?

        for step in workflow.steps {
            try Task.checkCancellation()

            guard let operation = step.operation else {
                throw NativWorkflowRunError.operationUnavailable(
                    step: step.id,
                    operation: step.type
                )
            }
            try verifyPermission(for: step, operation: operation, context: context)

            switch operation {
            case .readSelection:
                guard let read = await context.services.readSelection() else {
                    throw NativWorkflowRunError.nothingSelected
                }
                selection = read
                outputs[step.id] = ["text": .text(read.text)]

            case .invokeModel:
                guard let task = step.modelTask else {
                    throw NativWorkflowRunError.operationUnavailable(
                        step: step.id,
                        operation: step.type
                    )
                }
                let prompt = try resolvedText(step: step, input: "prompt", outputs: outputs)
                let response = try await context.services.invokeModel(
                    NativWorkflowModelRequest(
                        task: task,
                        requestedModel: step.model,
                        prompt: prompt,
                        maxTokens: step.maxTokens,
                        temperature: step.temperature
                    )
                )
                substitutedModel = response.substitutedModel ?? substitutedModel
                outputs[step.id] = ["text": .text(response.text)]

            case .replaceSelection:
                let text = try resolvedText(step: step, input: "text", outputs: outputs)
                guard let selection else {
                    throw NativWorkflowRunError.selectionUnavailable
                }
                // Past this point cancellation is ignored: a posted event
                // cannot be recalled, so stopping half way is worse than
                // finishing.
                guard await context.services.replaceSelection(text, selection) else {
                    throw NativWorkflowRunError.replaceFailed
                }
                outputs[step.id] = [:]

            case .readClipboard, .insertText, .recordAudio, .transcribeAudio,
                 .captureScreen, .saveFile, .writeClipboard, .showOverlay,
                 .showNotification, .readStorage, .writeStorage:
                throw NativWorkflowRunError.operationUnavailable(
                    step: step.id,
                    operation: step.type
                )
            }
        }

        return NativWorkflowRunSummary(
            extensionID: context.extensionID,
            commandID: commandID,
            stepsRun: workflow.steps.count,
            substitutedModel: substitutedModel
        )
    }

    /// The execution half of the permission rule. Redundant with the check the
    /// installer runs, deliberately: an installed package can be edited on
    /// disk, and a grant can be revoked after activation. This is the check
    /// that stands in for the XPC broker's, which in-process code bypasses.
    private static func verifyPermission(
        for step: NativWorkflowStep,
        operation: NativWorkflowOperation,
        context: NativWorkflowRunContext
    ) throws {
        let required: NativExtensionPermission?
        if operation == .invokeModel {
            required = step.modelTask?.requiredPermission
        } else {
            required = operation.requiredPermission
        }
        guard let required else { return }
        guard context.grantedPermissions.contains(required) else {
            throw NativWorkflowRunError.permissionNotGranted(
                step: step.id,
                permission: required
            )
        }
    }

    private static func resolvedText(
        step: NativWorkflowStep,
        input: String,
        outputs: [String: NativWorkflowStepOutput]
    ) throws -> String {
        guard case .text(let template)? = step.inputs[input] else {
            throw NativWorkflowRunError.missingInput(step: step.id, name: input)
        }
        return substitute(template, outputs: outputs)
    }

    /// Replaces every `{{step.output}}` with what that step produced. An
    /// unresolvable binding becomes empty rather than leaving the literal in
    /// place, so a prompt never contains its own template.
    static func substitute(
        _ template: String,
        outputs: [String: NativWorkflowStepOutput]
    ) -> String {
        var result = template
        for reference in NativWorkflowReference.references(in: template) {
            let name = reference.output ?? "text"
            let value = outputs[reference.step]?[name]?.text ?? ""
            let token = reference.output.map { "{{\(reference.step).\($0)}}" }
                ?? "{{\(reference.step)}}"
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }
}
