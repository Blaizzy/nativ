import Foundation

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
}
