import Foundation

@MainActor
enum ScheduledTaskChatLinker {
    static func ensureChat(
        for routine: Routine,
        runs: [RoutineRun],
        sessionStore: ChatSessionStore
    ) -> Routine {
        var linkedRoutine = routine
        let sessionID = existingSessionID(
            for: routine,
            runs: runs,
            sessionExists: { sessionStore.loadSession(id: $0) != nil }
        ) ?? routine.sourceSessionID ?? UUID()

        if var session = sessionStore.loadSession(id: sessionID) {
            let title = routine.name.isEmpty ? "Scheduled" : routine.name
            guard session.scheduledTaskID != routine.id || session.title != title else {
                linkedRoutine.sourceSessionID = sessionID
                return linkedRoutine
            }
            session.scheduledTaskID = routine.id
            session.title = title
            sessionStore.saveSession(session)
        } else {
            sessionStore.saveSession(makeSession(for: routine, id: sessionID))
        }
        linkedRoutine.sourceSessionID = sessionID
        return linkedRoutine
    }

    static func existingSessionID(
        for routine: Routine,
        runs: [RoutineRun],
        sessionExists: (UUID) -> Bool
    ) -> UUID? {
        if let sourceSessionID = routine.sourceSessionID,
           sessionExists(sourceSessionID) {
            return sourceSessionID
        }

        return runs
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap(\.sessionID)
            .first(where: sessionExists)
    }

    static func makeSession(for routine: Routine, id: UUID = UUID()) -> ChatSession {
        ChatSession(
            id: id,
            title: routine.name.isEmpty ? "Scheduled" : routine.name,
            customTitle: nil,
            createdAt: routine.createdAt,
            updatedAt: routine.createdAt,
            messages: [],
            pinned: nil,
            pinnedOrder: nil,
            sessionOrder: nil,
            folderID: nil,
            imageGenerationModelID: nil,
            scheduledTaskID: routine.id
        )
    }
}
