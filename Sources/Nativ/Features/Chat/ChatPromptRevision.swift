import Foundation

struct ChatPromptRevision: Equatable {
    let messages: [ChatTranscriptMessage]
    let discardedMessageCount: Int

    static func make(
        messageID: UUID,
        content: String,
        attachments: [ChatImageAttachment],
        modelID: String,
        createdAt: Date = Date(),
        in messages: [ChatTranscriptMessage]
    ) -> ChatPromptRevision? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              messages[messageIndex].role == .user
        else {
            return nil
        }

        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else {
            return nil
        }

        var revisedMessage = messages[messageIndex]
        revisedMessage.content = content
        revisedMessage.modelID = modelID
        revisedMessage.createdAt = createdAt
        revisedMessage.imageAttachments = attachments

        var revisedMessages = Array(messages[..<messageIndex])
        revisedMessages.append(revisedMessage)

        return ChatPromptRevision(
            messages: revisedMessages,
            discardedMessageCount: messages.count - messageIndex - 1
        )
    }

    static func discardedMessageCount(
        after messageID: UUID,
        in messages: [ChatTranscriptMessage]
    ) -> Int? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              messages[messageIndex].role == .user
        else {
            return nil
        }
        return messages.count - messageIndex - 1
    }
}
