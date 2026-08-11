import Foundation

enum ChatConversationBranch {
    static func latestUserMessageID(in messages: [ChatTranscriptMessage]) -> UUID? {
        messages.last(where: { $0.role == .user })?.id
    }

    static func replacingLatestUserMessage(
        _ messageID: UUID,
        with content: String,
        attachments: [ChatImageAttachment],
        modelID: String,
        newMessageID: UUID = UUID(),
        createdAt: Date = Date(),
        in messages: [ChatTranscriptMessage]
    ) -> [ChatTranscriptMessage]? {
        guard messageID == latestUserMessageID(in: messages),
              let messageIndex = messages.firstIndex(where: { $0.id == messageID })
        else {
            return nil
        }

        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else {
            return nil
        }

        let revisedMessage = ChatTranscriptMessage(
            id: newMessageID,
            role: .user,
            content: content,
            modelID: modelID,
            createdAt: createdAt,
            imageAttachments: attachments
        )
        return Array(messages[..<messageIndex]) + [revisedMessage]
    }

    static func throughAssistantResponse(
        _ messageID: UUID,
        in messages: [ChatTranscriptMessage]
    ) -> [ChatTranscriptMessage]? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              messages[messageIndex].role == .assistant,
              !messages[messageIndex].isStreaming
        else {
            return nil
        }

        let remainingMessages = messages.index(after: messageIndex)..<messages.endIndex
        let nextUserIndex = remainingMessages.first(where: { messages[$0].role == .user })
            ?? messages.endIndex
        return Array(messages[..<nextUserIndex])
    }
}
