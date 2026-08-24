import Foundation
import Testing

@Suite("Scheduled task chats")
@MainActor
struct ScheduledTaskChatLinkerTests {
    @Test("Deleting a task removes its schedule and history")
    func deletingTaskRemovesPersistedStateAndNotifiesScheduler() {
        let routine = Routine(name: "Daily brief")
        let run = RoutineRun(routineID: routine.id, source: .scheduled)
        let store = RoutineStore(routines: [routine], runs: [run])
        var didNotifyScheduler = false
        store.onRoutinesChanged = { didNotifyScheduler = true }

        store.delete(id: routine.id)

        #expect(store.routine(id: routine.id) == nil)
        #expect(store.runs(forRoutine: routine.id).isEmpty)
        #expect(didNotifyScheduler)
    }

    @Test("Deleting a chat keeps its task and run record")
    func deletingChatOnlyDetachesItsReference() {
        let sourceSessionID = UUID()
        let runSessionID = UUID()
        let routine = Routine(name: "Daily brief", sourceSessionID: sourceSessionID)
        let run = RoutineRun(
            routineID: routine.id,
            source: .scheduled,
            sessionID: runSessionID,
            status: .succeeded
        )
        let store = RoutineStore(routines: [routine], runs: [run])

        store.detachSession(runSessionID)

        #expect(store.routines.map(\.id) == [routine.id])
        #expect(store.runs.map(\.id) == [run.id])
        #expect(store.runs.first?.sessionID == nil)
        #expect(store.routines.first?.sourceSessionID == sourceSessionID)

        store.detachSession(sourceSessionID)

        #expect(store.routines.map(\.id) == [routine.id])
        #expect(store.runs.map(\.id) == [run.id])
        #expect(store.routines.first?.sourceSessionID == nil)
    }

    @Test("Each run chat has its own identity and transcript")
    func runChatsAreIndependent() {
        let routine = Routine(name: "Daily brief")
        let firstMessages = [ChatTranscriptMessage(role: .user, content: "First run")]
        let secondMessages = [ChatTranscriptMessage(role: .user, content: "Second run")]

        let first = ScheduledTaskChatLinker.makeRunSession(
            for: routine,
            messages: firstMessages
        )
        let second = ScheduledTaskChatLinker.makeRunSession(
            for: routine,
            messages: secondMessages
        )

        #expect(first.id != second.id)
        #expect(first.messages == firstMessages)
        #expect(second.messages == secondMessages)
        #expect(first.scheduledTaskID == routine.id)
        #expect(second.scheduledTaskID == routine.id)
    }

    @Test("A run chat uses the run timestamp and task metadata")
    func newRunChatMetadata() {
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 42)
        let routine = Routine(name: "Daily brief", createdAt: createdAt)
        let messages = [
            ChatTranscriptMessage(role: .user, content: "Summarize my calendar.")
        ]

        let session = ScheduledTaskChatLinker.makeRunSession(
            for: routine,
            messages: messages,
            id: sessionID,
            createdAt: createdAt
        )

        #expect(session.id == sessionID)
        #expect(session.title == "Daily brief")
        #expect(session.displayTitle == "Daily brief")
        #expect(session.createdAt == createdAt)
        #expect(session.messages == messages)
        #expect(session.scheduledTaskID == routine.id)
    }
}
