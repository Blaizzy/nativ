import XCTest

@MainActor
final class InferenceActivityCoordinatorTests: XCTestCase {
    func testSameResourceAllowsOnlyOneOperationAtATime() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let windowID = UUID()
        let firstOperation = UUID()
        let secondOperation = UUID()

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: windowID,
            operationID: firstOperation
        ))
        XCTAssertFalse(subject.begin(
            resource: resource,
            windowID: windowID,
            operationID: secondOperation
        ))

        subject.end(resource: resource, operationID: firstOperation)

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: windowID,
            operationID: secondOperation
        ))
    }

    func testDifferentResourcesCanRunConcurrently() {
        let subject = InferenceActivityCoordinator()

        XCTAssertTrue(
            subject.begin(
                resource: .chat(UUID()),
                windowID: UUID(),
                operationID: UUID()
            )
        )
        XCTAssertTrue(
            subject.begin(
                resource: .imageGeneration(UUID()),
                windowID: UUID(),
                operationID: UUID()
            )
        )
    }

    func testOnlyOwningOperationCanReleaseResource() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let owner = UUID()

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: owner
        ))
        subject.end(resource: resource, operationID: UUID())
        XCTAssertFalse(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: UUID()
        ))

        subject.end(resource: resource, operationID: owner)
        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: UUID()
        ))
    }

    func testReportsOwnershipOnlyToOtherWindows() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let ownerWindowID = UUID()

        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: ownerWindowID,
            operationID: UUID()
        ))
        XCTAssertFalse(subject.isOwnedByAnotherWindow(resource, windowID: ownerWindowID))
        XCTAssertTrue(subject.isOwnedByAnotherWindow(resource, windowID: UUID()))
    }

    func testReportsWhetherAnyInferenceIsActive() {
        let subject = InferenceActivityCoordinator()
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let operationID = UUID()

        XCTAssertFalse(subject.hasActiveOperations)
        XCTAssertTrue(subject.begin(
            resource: resource,
            windowID: UUID(),
            operationID: operationID
        ))
        XCTAssertTrue(subject.hasActiveOperations)

        subject.end(resource: resource, operationID: operationID)

        XCTAssertFalse(subject.hasActiveOperations)
    }

    func testModelSwitchIsBlockedWhileInferenceIsActive() {
        let coordinator = InferenceActivityCoordinator()
        let model = NativModel()
        let originalModelID = model.settings.normalized().languageModelID
        let resource = InferenceActivityCoordinator.Resource.chat(UUID())
        let operationID = UUID()
        model.observeInferenceActivity(coordinator)

        XCTAssertTrue(coordinator.begin(
            resource: resource,
            windowID: UUID(),
            operationID: operationID
        ))
        XCTAssertTrue(model.inferenceActivityInProgress)

        model.switchLanguageModel(to: "nativ-tests/model-switch-must-stay-blocked")

        XCTAssertEqual(model.settings.normalized().languageModelID, originalModelID)

        coordinator.end(resource: resource, operationID: operationID)
        XCTAssertFalse(model.inferenceActivityInProgress)
    }
}

final class SystemMonitorObservationPolicyTests: XCTestCase {
    func testSamplingStartsForFirstObserverAndStopsAfterLastObserver() {
        var policy = SystemMonitorObservationPolicy()
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(policy.begin(first))
        XCTAssertFalse(policy.begin(second))
        XCTAssertFalse(policy.end(first))
        XCTAssertTrue(policy.end(second))
    }

    func testDuplicateObservationEventsAreIdempotent() {
        var policy = SystemMonitorObservationPolicy()
        let observer = UUID()

        XCTAssertTrue(policy.begin(observer))
        XCTAssertFalse(policy.begin(observer))
        XCTAssertTrue(policy.end(observer))
        XCTAssertFalse(policy.end(observer))
    }

    func testPausedObservationRestartsOnlyWhenAnObserverRemains() {
        var policy = SystemMonitorObservationPolicy()
        let observer = UUID()

        XCTAssertTrue(policy.begin(observer))
        XCTAssertTrue(policy.pause())
        XCTAssertFalse(policy.pause())
        XCTAssertTrue(policy.resume())

        XCTAssertTrue(policy.pause())
        XCTAssertFalse(policy.end(observer))
        XCTAssertFalse(policy.resume())
    }
}
