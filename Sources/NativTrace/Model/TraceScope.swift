import Foundation

/// Correlation keys carried by every event.
///
/// All fields are optional because producers know different things: a call made
/// by an external client through the local server has a `requestID` and no
/// `sessionID`, while a composed chat request has both. Queries narrow on
/// whichever keys are present.
public struct TraceScope: Sendable, Hashable, Codable {
    /// Chat session the event belongs to, when one exists.
    public var sessionID: String?
    /// One user prompt and everything the model did in response.
    public var turnID: String?
    /// A single model call. Joins to `request_events.request_id` in the
    /// analytics database.
    public var requestID: String?
    /// Zero-based index of this call within its turn's tool loop.
    public var roundIndex: Int?
    /// Model that served the call, as reported by the producer.
    public var modelID: String?

    public init(
        sessionID: String? = nil,
        turnID: String? = nil,
        requestID: String? = nil,
        roundIndex: Int? = nil,
        modelID: String? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.requestID = requestID
        self.roundIndex = roundIndex
        self.modelID = modelID
    }
}
