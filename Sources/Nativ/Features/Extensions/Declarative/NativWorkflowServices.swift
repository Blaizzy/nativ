import Foundation
import NativExtensionSDK

/// Text the user had selected, plus enough context to put a replacement back
/// where it came from.
struct NativTextSelection: Sendable {
    let text: String
    let target: VoiceTranscriptInsertionTarget?
    /// Opaque link to the element the text was read from. Set by the reading
    /// service and handed back on replace; the runner never looks inside. It is
    /// deliberately not addressable as a workflow value — a process identifier
    /// is not something a package should be able to bind to.
    let origin: NativSelectionOrigin?

    init(
        text: String,
        target: VoiceTranscriptInsertionTarget? = nil,
        origin: NativSelectionOrigin? = nil
    ) {
        self.text = text
        self.target = target
        self.origin = origin
    }
}

/// Boxes the accessibility element and range a selection came from. Held as
/// `AnyObject` so this file stays free of the accessibility framework and can
/// be compiled into the test target.
@MainActor
final class NativSelectionOrigin {
    let element: AnyObject?
    let range: NSRange?

    init(element: AnyObject?, range: NSRange?) {
        self.element = element
        self.range = range
    }
}

struct NativWorkflowModelRequest: Sendable {
    let task: NativWorkflowModelTask
    let requestedModel: String?
    let prompt: String
    let maxTokens: Int?
    let temperature: Double?
}

/// Everything a workflow step reaches the outside world through.
///
/// Mirrors the injectable dependency structs on `ChatToolExecutionContext`, so
/// the runner can be exercised with no server, no model, and no accessibility
/// grant.
struct NativWorkflowModelResponse: Sendable {
    let text: String
    /// Set when the resolver had to use a model other than the one the
    /// workflow named, so the caller can say what it used instead.
    var substitutedModel: String?

    init(text: String, substitutedModel: String? = nil) {
        self.text = text
        self.substitutedModel = substitutedModel
    }
}

struct NativWorkflowServices: Sendable {
    var readSelection: @MainActor @Sendable () async -> NativTextSelection?
    var replaceSelection: @MainActor @Sendable (String, NativTextSelection) async -> Bool
    var invokeModel: @Sendable (NativWorkflowModelRequest) async throws -> NativWorkflowModelResponse
}

struct NativWorkflowRunContext: Sendable {
    /// Non-optional: in process nothing scopes anything by construction, so
    /// identity has to be impossible to forget.
    let extensionID: String
    let grantedPermissions: Set<NativExtensionPermission>
    let services: NativWorkflowServices
}

struct NativWorkflowRunSummary: Equatable, Sendable {
    let extensionID: String
    let commandID: String
    let stepsRun: Int
    /// Set when a model other than the one the workflow named was used.
    var substitutedModel: String?
}

enum NativWorkflowRunError: LocalizedError, Equatable {
    case permissionNotGranted(step: String, permission: NativExtensionPermission)
    case operationUnavailable(step: String, operation: String)
    case missingInput(step: String, name: String)
    case nothingSelected
    case selectionUnavailable
    case replaceFailed
    case noTriggerForCommand(String)

    var errorDescription: String? {
        switch self {
        case .permissionNotGranted(_, let permission):
            "This extension has not been granted “\(permission.displayName)”."
        case .operationUnavailable(let step, let operation):
            "Step “\(step)” uses “\(operation)”, which this version of Nativ cannot run."
        case .missingInput(let step, let name):
            "Step “\(step)” is missing its “\(name)” input."
        case .nothingSelected:
            "Select some text first."
        case .selectionUnavailable:
            "The selection is no longer available."
        case .replaceFailed:
            "Nativ could not replace the selected text."
        case .noTriggerForCommand(let commandID):
            "No workflow step runs “\(commandID)”."
        }
    }
}
