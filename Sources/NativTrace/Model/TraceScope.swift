import Foundation

public struct TraceScope: Sendable, Hashable, Codable {
    public var sessionID: String?
    public var turnID: String?
    public var requestID: String?
    public var roundIndex: Int?
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

