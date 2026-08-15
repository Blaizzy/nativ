import Foundation
import XCTest

@MainActor
final class RoutineLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativRoutineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testDeletingRoutineNotifiesRuntimeAndRemovesRuns() {
        let store = makeStore()
        let sessionID = UUID()
        let routine = Routine(sourceSessionID: sessionID)
        store.upsert(routine)

        var deletedID: String?
        store.onRoutineDeleted = { deletedID = $0 }
        let run = RoutineRun(
            routineID: routine.id,
            source: .scheduled,
            sessionID: sessionID
        )
        store.recordRun(run)

        store.deleteRoutine(forSession: sessionID)

        XCTAssertEqual(deletedID, routine.id)
        XCTAssertNil(store.routine(id: routine.id))
        XCTAssertTrue(store.runs(forRoutine: routine.id).isEmpty)
    }

    func testReconcileRemovesRoutinesWithoutSourceSessions() {
        let store = makeStore()
        let validSessionID = UUID()
        let orphanSessionID = UUID()
        let validRoutine = Routine(sourceSessionID: validSessionID)
        let orphanRoutine = Routine(sourceSessionID: orphanSessionID)
        store.upsert(validRoutine)
        store.upsert(orphanRoutine)

        let validRun = RoutineRun(
            routineID: validRoutine.id,
            source: .api,
            sessionID: validSessionID
        )
        let orphanRun = RoutineRun(
            routineID: orphanRoutine.id,
            source: .api,
            sessionID: orphanSessionID
        )
        store.recordRun(validRun)
        store.recordRun(orphanRun)

        let removed = store.reconcile(sourceSessionIDs: [validSessionID])

        XCTAssertEqual(removed, [orphanRoutine.id])
        XCTAssertNotNil(store.routine(id: validRoutine.id))
        XCTAssertNil(store.routine(id: orphanRoutine.id))
        XCTAssertEqual(store.runs(forRoutine: validRoutine.id), [validRun])
        XCTAssertTrue(store.runs(forRoutine: orphanRoutine.id).isEmpty)
    }

    func testLateRunCompletionCannotResurrectDeletedRoutine() {
        let store = makeStore()
        let routine = Routine(sourceSessionID: UUID())
        store.upsert(routine)
        store.delete(id: routine.id)

        store.recordRun(
            RoutineRun(
                routineID: routine.id,
                source: .scheduled,
                status: .succeeded
            )
        )

        XCTAssertNil(store.routine(id: routine.id))
        XCTAssertTrue(store.runs(forRoutine: routine.id).isEmpty)
        XCTAssertTrue(store.runs.isEmpty)
    }

    func testRoutineWithoutSourceSessionCannotBePersisted() {
        let store = makeStore()
        store.upsert(Routine())

        XCTAssertTrue(store.routines.isEmpty)
    }

    private func makeStore() -> RoutineStore {
        RoutineStore(persistence: RoutineStore.Persistence(directory: directory))
    }
}
