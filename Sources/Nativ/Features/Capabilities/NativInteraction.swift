import Foundation

protocol NativInteraction: Sendable {
    @MainActor
    func requestConsent(for toolName: String, requestID: UUID) async -> ChatToolConsentOutcome
}

struct ChatConsentAsker: NativInteraction {
    let chat: ChatViewModel
    let sessionID: UUID

    @MainActor
    func requestConsent(for toolName: String, requestID: UUID) async -> ChatToolConsentOutcome {
        await chat.answerToolConsent(requestID: requestID, in: sessionID)
    }
}
