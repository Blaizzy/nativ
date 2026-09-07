import Foundation
import NativTrace

/// One user prompt and everything the model does in response.
struct ChatTraceTurn: Hashable {
    let sessionID: UUID
    let turnID: UUID
}

/// One model call within a turn.
///
/// Exists so producer methods take a single value instead of repeating
/// `sessionID:turnID:requestID:` at every call site, where a transposed pair of
/// identifiers would still compile and quietly file events under the wrong turn.
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

/// Whether an error means the user stopped the work rather than the work broke.
///
/// Two error types mean cancellation here: `CancellationError` from structured
/// concurrency, and `URLError.cancelled` from tearing down a streaming session.
/// The chat loop's catch clauses already treat both that way; anything deciding
/// the same question must agree with them or a stopped response gets recorded
/// as a failure.
func ChatIsCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}
