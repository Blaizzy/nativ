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
        context: NativWorkflowRunContext,
        onProgress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> NativWorkflowRunSummary {
        guard workflow.trigger(forCommand: commandID) != nil else {
            throw NativWorkflowRunError.noTriggerForCommand(commandID)
        }

        let steps = workflow.steps(forCommand: commandID)
        var outputs: [String: NativWorkflowStepOutput] = [:]
        var selection: NativTextSelection?
        var substitutedModel: String?

        for (index, step) in steps.enumerated() {
            await onProgress(index, steps.count)
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

            case .readStorage:
                let key = try resolvedText(step: step, input: "key", outputs: [:])
                outputs[step.id] = ["value": try await context.services.readStorage(key)]

            case .writeStorage:
                let key = try resolvedText(step: step, input: "key", outputs: [:])
                guard let authored = step.inputs["value"] else {
                    throw NativWorkflowRunError.missingInput(step: step.id, name: "value")
                }
                let value = resolvedValue(authored, outputs: outputs)
                try Task.checkCancellation()
                try await context.services.writeStorage(key, value)
                outputs[step.id] = [:]

            case .readClipboard, .insertText, .recordAudio, .transcribeAudio,
                 .captureScreen, .saveFile, .writeClipboard, .showOverlay,
                 .showNotification:
                throw NativWorkflowRunError.operationUnavailable(
                    step: step.id,
                    operation: step.type
                )
            }
        }

        try Task.checkCancellation()
        await onProgress(steps.count, steps.count)
        return NativWorkflowRunSummary(
            extensionID: context.extensionID,
            commandID: commandID,
            stepsRun: steps.count,
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

    static func resolvedValue(
        _ value: NativWorkflowValue,
        outputs: [String: NativWorkflowStepOutput]
    ) -> NativWorkflowValue {
        guard case .text(let template) = value else { return value }
        for reference in NativWorkflowReference.references(in: template) {
            let token = reference.output.map { "{{\(reference.step).\($0)}}" } ?? "{{\(reference.step)}}"
            if template == token {
                return outputs[reference.step]?[reference.output ?? "text"] ?? .none
            }
        }
        return .text(substitute(template, outputs: outputs))
    }

    static func scalarText(_ value: NativWorkflowValue) -> String {
        switch value {
        case .text(let text): text
        case .number(let number): String(number)
        case .boolean(let flag): flag ? "true" : "false"
        default: ""
        }
    }

    /// Replace ranges in the authored template only, so values containing
    /// template syntax cannot read another step's output.
    static func substitute(
        _ template: String,
        outputs: [String: NativWorkflowStepOutput]
    ) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "\\{\\{([A-Za-z0-9_.-]+)\\}\\}") else { return template }
        let result = NSMutableString(string: template)
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: result.length)).reversed() {
            let raw = (template as NSString).substring(with: match.range(at: 1))
            guard let reference = NativWorkflowReference(raw) else { continue }
            let value = outputs[reference.step]?[reference.output ?? "text"] ?? .none
            result.replaceCharacters(in: match.range, with: scalarText(value))
        }
        return result as String
    }
}
