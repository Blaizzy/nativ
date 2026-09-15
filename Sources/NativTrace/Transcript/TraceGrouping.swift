import Foundation

public struct TraceTurn: Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: TraceItem?
    public let segments: [TraceItem]
}

public enum TraceDisplayBlock: Sendable, Hashable, Identifiable {
    case turn(TraceTurn)
    case boundary(TraceItem)

    public var id: String {
        switch self {
        case .turn(let turn): "turn:\(turn.id)"
        case .boundary(let item): "boundary:\(item.id)"
        }
    }
}

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
                segments: currentSegments
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

    private static func isBoundary(_ item: TraceItem) -> Bool {
        guard case .lifecycle(let lifecycle) = item.body else { return false }
        switch lifecycle.kind {
        case .sessionStarted, .modelSwitched: return true
        case .turnEnded, .failure: return false
        }
    }
}

