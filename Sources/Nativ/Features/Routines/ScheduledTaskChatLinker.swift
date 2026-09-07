import Foundation

enum ScheduledTaskChatDisposition {
    case keepChats
    case deleteChats
}

@MainActor
enum ScheduledTaskChatLinker {
    static func makeRunSession(
        for routine: Routine,
        messages: [ChatTranscriptMessage],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> ChatSession {
        ChatSession(
            id: id,
            title: routine.name.isEmpty ? "Scheduled" : routine.name,
            customTitle: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: messages,
            pinned: nil,
            pinnedOrder: nil,
            sessionOrder: nil,
            folderID: nil,
            imageGenerationModelID: nil,
            scheduledTaskID: routine.id
        )
    }

    static func linkedSessionIDs(for routine: Routine, runs: [RoutineRun]) -> Set<UUID> {
        Set(
            [routine.sourceSessionID].compactMap { $0 }
                + runs.compactMap(\.sessionID)
        )
    }

    static func makeIndependentSession(from session: ChatSession) -> ChatSession {
        var detached = session
        if detached.customTitle?.isEmpty != false {
            detached.customTitle = detached.displayTitle
        }
        detached.scheduledTaskID = nil
        return detached
    }
}
