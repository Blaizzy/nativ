import Foundation

struct ChatPromptRevision: Equatable {
    let messages: [ChatTranscriptMessage]

    static func latestUserMessageID(in messages: [ChatTranscriptMessage]) -> UUID? {
        messages.last(where: { $0.role == .user })?.id
    }

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

        return ChatPromptRevision(messages: revisedMessages)
    }
}
