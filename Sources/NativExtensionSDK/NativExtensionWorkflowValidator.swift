import Foundation

public enum NativExtensionWorkflowError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case noTriggers
    case noSteps
    case duplicateStep(String)
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

/// Checks a workflow against its manifest.
///
/// The rules here are the same ones the marketplace enforces in
/// `scripts/validate.py` (Marvis-Labs/nativ-extensions). Both copies are
/// deliberate: the catalog cannot be trusted by the host, and a sideloaded
/// package never passes through the catalog at all. Keep them in step.
public enum NativExtensionWorkflowValidator {
    /// Operations with a working implementation. The rest are known to the
    /// schema so a catalog entry using one is still listable, but a package is
    /// refused at install rather than accepted and failing on first use.
    public static let implementedOperations: Set<NativWorkflowOperation> = [
        .readSelection,
        .invokeModel,
        .replaceSelection,
    ]

    public static func validate(
        _ workflow: NativExtensionWorkflow,
        manifest: NativExtensionManifest,
        implemented: Set<NativWorkflowOperation> = implementedOperations
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

        let commandIDs = Set(manifest.contributions.commands.map(\.id))
        for trigger in workflow.triggers where trigger.type == .command {
            let commandID = trigger.commandID ?? ""
            guard commandIDs.contains(commandID) else {
                throw NativExtensionWorkflowError.undeclaredCommand(
                    trigger: trigger.id,
                    commandID: commandID
                )
            }
        }

        let declared = Set(manifest.permissions)
        var produced = Set<String>()
        for step in workflow.steps {
            guard produced.insert(step.id).inserted else {
                throw NativExtensionWorkflowError.duplicateStep(step.id)
            }
            let operation = try resolve(step)
            guard implemented.contains(operation) else {
                throw NativExtensionWorkflowError.unimplementedOperation(
                    step: step.id,
                    operation: step.type
                )
            }
            try verifyPermission(for: step, operation: operation, declared: declared)
            try verifyReferences(in: step, produced: produced)
        }
    }

    private static func resolve(_ step: NativWorkflowStep) throws -> NativWorkflowOperation {
        guard let operation = step.operation else {
            throw NativExtensionWorkflowError.unknownOperation(
                step: step.id,
                operation: step.type
            )
        }
        return operation
    }

    /// The rule that makes the permission list a user reviews complete by
    /// construction: a package cannot run an operation it never asked for.
    private static func verifyPermission(
        for step: NativWorkflowStep,
        operation: NativWorkflowOperation,
        declared: Set<NativExtensionPermission>
    ) throws {
        let required: NativExtensionPermission
        if operation == .invokeModel {
            guard let task = step.modelTask else {
                throw NativExtensionWorkflowError.unknownModelTask(
                    step: step.id,
                    task: step.task ?? ""
                )
            }
            required = task.requiredPermission
        } else if let permission = operation.requiredPermission {
            required = permission
        } else {
            return
        }
        guard declared.contains(required) else {
            throw NativExtensionWorkflowError.undeclaredPermission(
                step: step.id,
                operation: step.type,
                permission: required
            )
        }
    }

    /// A step may only read from steps that have already run. `storage` is the
    /// one binding that does not name a step.
    private static func verifyReferences(
        in step: NativWorkflowStep,
        produced: Set<String>
    ) throws {
        for value in step.inputs.values {
            for reference in value.references {
                guard reference.step != "storage" else { continue }
                guard produced.contains(reference.step), reference.step != step.id else {
                    throw NativExtensionWorkflowError.unresolvedReference(
                        step: step.id,
                        reference: reference.output.map { "\(reference.step).\($0)" }
                            ?? reference.step
                    )
                }
            }
        }
    }
}
