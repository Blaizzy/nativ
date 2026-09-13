import Foundation
import NativTrace

struct ChatTraceTurn: Hashable {
    let sessionID: UUID
    let turnID: UUID
}

struct ChatTraceCall: Hashable {
    let turn: ChatTraceTurn
    let requestID: UUID
    let round: Int
    let modelID: String?

    var sessionID: UUID { turn.sessionID }
    var turnID: UUID { turn.turnID }
}

extension ChatTraceTurn {
    func scope(modelID: String? = nil) -> TraceScope {
        TraceScope(
            sessionID: sessionID.uuidString,
            turnID: turnID.uuidString,
            modelID: modelID
        )
    }
}

extension ChatTraceCall {
    func scope() -> TraceScope {
        TraceScope(
            sessionID: sessionID.uuidString,
            turnID: turnID.uuidString,
            requestID: requestID.uuidString,
            roundIndex: round,
            modelID: modelID
        )
    }
}

func ChatIsCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}
