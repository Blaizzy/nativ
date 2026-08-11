import Foundation

enum ChatConversationBranch {
    static func throughAssistantResponse(
        _ messageID: UUID,
        in source: ChatSession,
        branchID: UUID = UUID(),
        createdAt: Date = Date()
    ) -> ChatSession? {
        guard let turnEndIndex = completedAssistantTurnEndIndex(
            messageID,
            in: source.messages
        ) else {
            return nil
        }
        let messages = Array(source.messages[..<turnEndIndex])

        return make(
            from: source,
            messages: messages,
            id: branchID,
            createdAt: createdAt
        )
    }

    static func forkableAssistantResponseIDs(
        in messages: [ChatTranscriptMessage]
    ) -> Set<UUID> {
        var responseIDs: Set<UUID> = []
        var turnStartIndex = messages.startIndex

        for messageIndex in messages.indices where messages[messageIndex].role == .user {
            if turnStartIndex < messageIndex,
               let responseID = forkableResponseID(
                   in: messages[turnStartIndex..<messageIndex]
               ) {
                responseIDs.insert(responseID)
            }
            turnStartIndex = messageIndex
        }

        if turnStartIndex < messages.endIndex,
           let responseID = forkableResponseID(
               in: messages[turnStartIndex..<messages.endIndex]
           ) {
            responseIDs.insert(responseID)
        }

        return responseIDs
    }

    private static func completedAssistantTurnEndIndex(
        _ messageID: UUID,
        in messages: [ChatTranscriptMessage]
    ) -> Int? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              messages[messageIndex].role == .assistant
        else {
            return nil
        }

        let turnStartIndex = messages[..<messageIndex]
            .lastIndex(where: { $0.role == .user })
            ?? messages.startIndex
        let remainingMessageIndices = messages.index(after: messageIndex)..<messages.endIndex
        let nextUserIndex = remainingMessageIndices
            .first(where: { messages[$0].role == .user })
            ?? messages.endIndex
        let turn = messages[turnStartIndex..<nextUserIndex]
        guard forkableResponseID(in: turn) == messageID else {
            return nil
        }
        return nextUserIndex
    }

    private static func forkableResponseID(
        in turn: ArraySlice<ChatTranscriptMessage>
    ) -> UUID? {
        guard turn.first?.role == .user,
              let finalAssistantResponse = turn.last,
              finalAssistantResponse.role == .assistant,
              turn.allSatisfy(isComplete),
              hasMatchingToolCallsAndResults(in: turn)
        else {
            return nil
        }
        return finalAssistantResponse.id
    }

    private static func isComplete(_ message: ChatTranscriptMessage) -> Bool {
        guard !message.isStreaming else {
            return false
        }
        switch message.toolStatus {
        case .preparing, .awaitingImageModelSelection, .running, .awaitingConsent:
            return false
        case .succeeded, .failed, .cancelled, .declined, nil:
            return true
        }
    }

    private static func hasMatchingToolCallsAndResults(
        in messages: ArraySlice<ChatTranscriptMessage>
    ) -> Bool {
        var unresolvedToolCallIDs: Set<String> = []

        for message in messages {
            for toolCall in message.toolCalls {
                guard let id = toolCall.id,
                      !id.isEmpty,
                      unresolvedToolCallIDs.insert(id).inserted
                else {
                    return false
                }
            }

            if message.role == .tool {
                guard let id = message.toolCallID,
                      !id.isEmpty,
                      unresolvedToolCallIDs.remove(id) != nil
                else {
                    return false
                }
            }
        }

        return unresolvedToolCallIDs.isEmpty
    }

    static func make(
        from source: ChatSession,
        messages: [ChatTranscriptMessage],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> ChatSession {
        ChatSession(
            id: id,
            title: ChatSession.defaultTitle(for: messages, createdAt: createdAt),
            customTitle: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: messages,
            pinned: false,
            pinnedOrder: nil,
            sessionOrder: nil,
            folderID: source.folderID,
            imageGenerationModelID: source.imageGenerationModelID
        )
    }
}
