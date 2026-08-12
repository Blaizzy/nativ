import Foundation
import Testing

@Suite("Scheduled task chats")
@MainActor
struct ScheduledTaskChatLinkerTests {
    @Test("An existing source chat remains canonical")
    func existingSourceChatWins() {
        let sourceID = UUID()
        let newerRunID = UUID()
        let routine = Routine(sourceSessionID: sourceID)
        let run = RoutineRun(
            routineID: routine.id,
            startedAt: Date(),
            source: .scheduled,
            sessionID: newerRunID
        )

        let resolved = ScheduledTaskChatLinker.existingSessionID(
            for: routine,
            runs: [run],
            sessionExists: { $0 == sourceID || $0 == newerRunID }
        )

        #expect(resolved == sourceID)
    }

    @Test("The latest existing run chat repairs a missing source link")
    func latestRunRepairsMissingLink() {
        let olderID = UUID()
        let newerID = UUID()
        let routine = Routine()
        let runs = [
            RoutineRun(
                routineID: routine.id,
                startedAt: Date(timeIntervalSince1970: 1),
                source: .scheduled,
                sessionID: olderID
            ),
            RoutineRun(
                routineID: routine.id,
                startedAt: Date(timeIntervalSince1970: 2),
                source: .scheduled,
                sessionID: newerID
            ),
        ]

        let resolved = ScheduledTaskChatLinker.existingSessionID(
            for: routine,
            runs: runs,
            sessionExists: { $0 == olderID || $0 == newerID }
        )

        #expect(resolved == newerID)
    }

    @Test("A new source chat is marked as a scheduled task")
    func newSourceChatMetadata() {
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 42)
        let routine = Routine(name: "Daily brief", createdAt: createdAt)

        var session = ScheduledTaskChatLinker.makeSession(for: routine, id: sessionID)
        #expect(session.messages.isEmpty)
        session.messages = [
            ChatTranscriptMessage(role: .user, content: "Summarize my calendar.")
        ]

        #expect(session.id == sessionID)
        #expect(session.title == "Daily brief")
        #expect(session.displayTitle == "Daily brief")
        #expect(session.createdAt == createdAt)
        #expect(session.scheduledTaskID == routine.id)
    }
}
