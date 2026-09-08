import Foundation

public enum NativExtensionWorkflowError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case noTriggers
    case noSteps
    case duplicateStep(String)
    case invalidWorkflow(String)
    case invalidStep(step: String, reason: String)
    case unknownOperation(step: String, operation: String)
    case unimplementedOperation(step: String, operation: String)
    case unknownModelTask(step: String, task: String)
    case undeclaredPermission(
        step: String,
        operation: String,
        permission: NativExtensionPermission
    )
    case unresolvedReference(step: String, reference: String)
    case undeclaredCommand(trigger: String, commandID: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Workflow schema \(version) is not supported."
        case .noTriggers:
            "The workflow does not declare a trigger."
        case .noSteps:
            "The workflow does not declare any steps."
        case .invalidWorkflow(let reason):
            reason
        case .invalidStep(let step, let reason):
            "Step “\(step)”: \(reason)"
        case .duplicateStep(let id):
            "The workflow declares the step “\(id)” more than once."
        case .unknownOperation(let step, let operation):
            "Step “\(step)” uses “\(operation)”, which is not an allowed operation."
        case .unimplementedOperation(let step, let operation):
            "Step “\(step)” uses “\(operation)”, which this version of Nativ cannot run yet."
        case .unknownModelTask(let step, let task):
            "Step “\(step)” asks for the model task “\(task)”, which does not exist."
        case .undeclaredPermission(let step, let operation, let permission):
            "Step “\(step)” uses \(operation) but the extension does not ask for “\(permission.displayName)”."
        case .unresolvedReference(let step, let reference):
            "Step “\(step)” refers to “\(reference)” before it is produced."
        case .undeclaredCommand(let trigger, let commandID):
            "Trigger “\(trigger)” runs “\(commandID)”, which the extension does not contribute."
        }
    }
}

/// The install-time contract shared by Nativ and the registry CLI.
public enum NativExtensionWorkflowValidator {
    public static let maximumSteps = 64
    public static let maximumTriggers = 32
    public static let maximumTextBytes = 65_536
    public static let maximumModelTokens = 8_192
    public static let implementedOperations: Set<NativWorkflowOperation> = [
        .readSelection, .invokeModel, .replaceSelection,
    ]

    public static func validate(
        _ workflow: NativExtensionWorkflow,
        manifest: NativExtensionManifest
    ) throws {
        guard workflow.schemaVersion == NativExtensionWorkflow.currentSchemaVersion else {
            throw NativExtensionWorkflowError.unsupportedSchema(workflow.schemaVersion)
        }
        guard !workflow.triggers.isEmpty else {
            throw NativExtensionWorkflowError.noTriggers
        }
        guard !workflow.steps.isEmpty else {
            throw NativExtensionWorkflowError.noSteps
        }
        guard workflow.steps.count <= maximumSteps,
              workflow.triggers.count <= maximumTriggers else {
            throw NativExtensionWorkflowError.invalidWorkflow(
                "A workflow may contain at most \(maximumSteps) steps and \(maximumTriggers) triggers."
            )
        }
        try verifyTriggers(workflow.triggers, manifest: manifest)

        let declared = Set(manifest.permissions)
        var outputs: [String: Set<String>] = [:]
        var hasSelection = false
        for step in workflow.steps {
            guard validIdentifier(step.id) else {
                throw invalid(step, "Use a step ID of 1–64 letters, digits, underscores, or hyphens; storage is reserved.")
            }
            guard outputs[step.id] == nil else {
                throw NativExtensionWorkflowError.duplicateStep(step.id)
            }
            guard let operation = step.operation else {
                throw NativExtensionWorkflowError.unknownOperation(step: step.id, operation: step.type)
            }
            guard implementedOperations.contains(operation) else {
                throw NativExtensionWorkflowError.unimplementedOperation(step: step.id, operation: step.type)
            }
            try verifyPermission(for: step, operation: operation, declared: declared)
            try verifyReferences(in: step, outputs: outputs)
            let input: String?
            switch operation {
            case .readSelection: input = nil
            case .invokeModel: input = "prompt"
            case .replaceSelection: input = "text"
            default: throw NativExtensionWorkflowError.unimplementedOperation(step: step.id, operation: step.type)
            }
            let expectedInputs = Set(input.map { [$0] } ?? [])
            guard Set(step.inputs.keys) == expectedInputs else {
                throw invalid(step, input.map { "Provide only the required “\($0)” text input." }
                    ?? "This operation does not accept inputs.")
            }
            if let input {
                guard case .text(let text)? = step.inputs[input],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= maximumTextBytes else {
                    throw invalid(step, "“\(input)” must be nonempty text of at most \(maximumTextBytes) UTF-8 bytes.")
                }
                guard !NativWorkflowReference.hasMalformedReferences(in: text) else {
                    throw invalid(step, "Use bindings of the form {{step}} or {{step.output}}.")
                }
            }
            if operation == .invokeModel {
                guard step.modelTask == .language else {
                    throw invalid(step, "This version of Nativ supports only the language model task.")
                }
                if let tokens = step.maxTokens, !(1...maximumModelTokens).contains(tokens) {
                    throw invalid(step, "maxTokens must be between 1 and \(maximumModelTokens).")
                }
                if let temperature = step.temperature,
                   !temperature.isFinite || !(0...2).contains(temperature) {
                    throw invalid(step, "temperature must be a finite number between 0 and 2.")
                }
                if let model = step.model,
                   model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.utf8.count > 512 {
                    throw invalid(step, "model must be a nonempty identifier of at most 512 UTF-8 bytes.")
                }
            } else if step.task != nil || step.model != nil || step.maxTokens != nil || step.temperature != nil {
                throw invalid(step, "Model options are only supported by model.invoke.")
            }
            if operation == .replaceSelection, !hasSelection {
                throw invalid(step, "Read a selection before replacing it.")
            }
            hasSelection = hasSelection || operation == .readSelection
            outputs[step.id] = operation == .replaceSelection ? [] : ["text"]
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value != "storage" && !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
    }

    private static func invalid(_ step: NativWorkflowStep, _ reason: String) -> NativExtensionWorkflowError {
        .invalidStep(step: step.id, reason: reason)
    }

    private static func verifyTriggers(
        _ triggers: [NativWorkflowTrigger],
        manifest: NativExtensionManifest
    ) throws {
        let commandIDs = Set(manifest.contributions.commands.map(\.id))
        var identifiers = Set<String>()
        var triggeredCommands = Set<String>()
        for trigger in triggers {
            guard validIdentifier(trigger.id), identifiers.insert(trigger.id).inserted else {
                throw NativExtensionWorkflowError.invalidWorkflow("Trigger IDs must be valid and unique.")
            }
            guard trigger.type == .command, trigger.shortcut == nil else {
                throw NativExtensionWorkflowError.invalidWorkflow("Only command triggers are supported by this version of Nativ.")
            }
            let commandID = trigger.commandID ?? ""
            guard commandIDs.contains(commandID) else {
                throw NativExtensionWorkflowError.undeclaredCommand(trigger: trigger.id, commandID: commandID)
            }
            guard triggeredCommands.insert(commandID).inserted else {
                throw NativExtensionWorkflowError.invalidWorkflow("A command may have only one workflow trigger.")
            }
        }
        guard triggeredCommands == commandIDs else {
            throw NativExtensionWorkflowError.invalidWorkflow("Every contributed command must have a workflow trigger.")
        }
    }

    private static func verifyPermission(
        for step: NativWorkflowStep,
        operation: NativWorkflowOperation,
        declared: Set<NativExtensionPermission>
    ) throws {
        let required: NativExtensionPermission
        if operation == .invokeModel {
            guard let task = step.modelTask else {
                throw NativExtensionWorkflowError.unknownModelTask(step: step.id, task: step.task ?? "")
            }
            required = task.requiredPermission
        } else if let permission = operation.requiredPermission {
            required = permission
        } else {
            return
        }
        guard declared.contains(required) else {
            throw NativExtensionWorkflowError.undeclaredPermission(
                step: step.id, operation: step.type, permission: required
            )
        }
    }

    private static func verifyReferences(
        in step: NativWorkflowStep,
        outputs: [String: Set<String>]
    ) throws {
        for value in step.inputs.values {
            for reference in value.references {
                guard let produced = outputs[reference.step] else {
                    throw NativExtensionWorkflowError.unresolvedReference(
                        step: step.id,
                        reference: reference.output.map { "\(reference.step).\($0)" } ?? reference.step
                    )
                }
                let output = reference.output ?? "text"
                guard produced.contains(output) else {
                    throw invalid(step, "“\(reference.step)” does not produce “\(output)”.")
                }
            }
        }
    }
}
