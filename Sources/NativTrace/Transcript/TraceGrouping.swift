import Foundation

/// One user prompt and everything the model did in response.
public struct TraceTurn: Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: TraceItem?
    public let segments: [TraceItem]
    public let startedAt: Date
}

public enum TraceDisplayBlock: Sendable, Hashable, Identifiable {
    case turn(TraceTurn)
    /// A lifecycle item that separates two stretches of a trace — a chat
    /// starting, or one model taking over. Carried as the item itself rather
    /// than copied into a parallel type.
    case boundary(TraceItem)

    public var id: String {
        switch self {
        case .turn(let turn): "turn:\(turn.id)"
        case .boundary(let item): "boundary:\(item.id)"
        }
    }
}

/// Stage three of the fold: presentation.
///
/// Kept separate from `TraceReducer` because these are display choices — where
/// to draw a divider, what belongs to which turn — and they must not leak into
/// the semantic layer. Changing a grouping rule can never lose an item: every
/// input item appears in exactly one output block, and a test says so.
public enum TraceGrouping {
    public static func blocks(for items: [TraceItem]) -> [TraceDisplayBlock] {
        var blocks: [TraceDisplayBlock] = []
        var currentTurnID: String?
        var currentPrompt: TraceItem?
        var currentSegments: [TraceItem] = []

        func flushTurn() {
            guard currentPrompt != nil || !currentSegments.isEmpty else { return }
            blocks.append(.turn(TraceTurn(
                id: currentTurnID ?? currentPrompt?.id ?? currentSegments.first?.id ?? UUID().uuidString,
                prompt: currentPrompt,
                segments: currentSegments,
                startedAt: currentPrompt?.timestamp ?? currentSegments.first?.timestamp ?? .distantPast
            )))
            currentTurnID = nil
            currentPrompt = nil
            currentSegments = []
        }

        for item in items {
            if isBoundary(item) {
                flushTurn()
                blocks.append(.boundary(item))
                continue
            }

            if case .message(let message) = item.body, message.role == .user {
                flushTurn()
                currentTurnID = item.scope.turnID ?? item.id
                currentPrompt = item
                continue
            }

            if let turnID = item.scope.turnID, let openTurn = currentTurnID, turnID != openTurn {
                flushTurn()
                currentTurnID = turnID
            } else if currentTurnID == nil {
                currentTurnID = item.scope.turnID
            }
            currentSegments.append(item)
        }
        flushTurn()

        return blocks
    }

    /// Only these two lifecycle kinds divide a trace; the rest belong to a turn.
    private static func isBoundary(_ item: TraceItem) -> Bool {
        guard case .lifecycle(let lifecycle) = item.body else { return false }
        switch lifecycle.kind {
        case .sessionStarted, .modelSwitched: return true
        case .turnEnded, .failure: return false
        }
    }
}
