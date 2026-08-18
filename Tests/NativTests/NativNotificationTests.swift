import Foundation
import Testing

@Suite("Notifications")
struct NativNotificationTests {
    @Test("Generic notifications have safe defaults")
    func genericDefaults() {
        let notification = NativNotification(title: "Model ready", body: "Qwen is available.")

        #expect(!notification.identifier.isEmpty)
        #expect(notification.metadata.isEmpty)
        #expect(notification.playsSound)
    }

    @Test("Scheduled task completion includes its name and destination")
    func scheduledTaskCompletion() {
        let sessionID = UUID()
        let routine = Routine(name: "Daily brief")
        let run = RoutineRun(
            id: "run-1",
            routineID: routine.id,
            source: .scheduled,
            sessionID: sessionID,
            status: .succeeded
        )

        let notification = NativNotification.scheduledTaskCompletion(
            routine: routine,
            run: run
        )

        #expect(notification.identifier == "run-1")
        #expect(notification.title == "Your scheduled task completed")
        #expect(notification.body == "Daily brief")
        #expect(notification.metadata["sessionID"] == sessionID.uuidString)
    }

    @Test("Scheduled task failure is reported accurately")
    func scheduledTaskFailure() {
        let routine = Routine(name: "Daily brief")
        let run = RoutineRun(
            routineID: routine.id,
            source: .scheduled,
            status: .failed
        )

        let notification = NativNotification.scheduledTaskCompletion(
            routine: routine,
            run: run
        )

        #expect(notification.title == "Your scheduled task failed")
        #expect(notification.body == "Daily brief")
        #expect(notification.metadata.isEmpty)
    }
}
