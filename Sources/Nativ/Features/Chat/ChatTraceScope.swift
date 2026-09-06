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
