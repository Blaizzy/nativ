import Foundation
import Observation

@MainActor
@Observable
final class InferenceActivityCoordinator {
    enum Resource: Hashable {
        case chat(UUID)
        case imageGeneration(UUID)
    }

    private struct Activity {
        let windowID: UUID
        let operationID: UUID
    }

    private var activityByResource: [Resource: Activity] = [:]

    var hasActiveOperations: Bool {
        !activityByResource.isEmpty
    }

    func begin(resource: Resource, windowID: UUID, operationID: UUID) -> Bool {
        guard activityByResource[resource] == nil else {
            return false
        }
        activityByResource[resource] = Activity(
            windowID: windowID,
            operationID: operationID
        )
        return true
    }

    func end(resource: Resource, operationID: UUID) {
        guard activityByResource[resource]?.operationID == operationID else {
            return
        }
        activityByResource[resource] = nil
    }

    func isOwnedByAnotherWindow(_ resource: Resource, windowID: UUID) -> Bool {
        guard let activity = activityByResource[resource] else {
            return false
        }
        return activity.windowID != windowID
    }
}
