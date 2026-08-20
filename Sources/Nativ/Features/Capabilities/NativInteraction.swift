import Foundation

protocol NativInteraction: Sendable {
    @MainActor
    func requestConsent(for toolName: String, requestID: UUID) async -> ChatToolConsentOutcome
}
