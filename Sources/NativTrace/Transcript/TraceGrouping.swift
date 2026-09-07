import Foundation

/// One user prompt and everything the model did in response.
public struct TraceTurn: Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: TraceItem?
    public let segments: [TraceItem]
    public let startedAt: Date
}

/// A divider between stretches of a trace that were not the same context.
public struct TraceBoundary: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case sessionStarted
        case modelSwitched
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let timestamp: Date
}

public enum TraceDisplayBlock: Sendable, Hashable, Identifiable {
    case turn(TraceTurn)
    case boundary(TraceBoundary)
    case loose(TraceItem)

    public var id: String {
        switch self {
        case .turn(let turn): "turn:\(turn.id)"
        case .boundary(let boundary): "boundary:\(boundary.id)"
        case .loose(let item): "loose:\(item.id)"
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
            if let boundary = boundary(for: item) {
                flushTurn()
                blocks.append(.boundary(boundary))
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

    private static func boundary(for item: TraceItem) -> TraceBoundary? {
        guard case .lifecycle(let lifecycle) = item.body else { return nil }
        switch lifecycle.kind {
        case .sessionStarted:
            return TraceBoundary(
                id: item.id, kind: .sessionStarted, title: lifecycle.title,
                detail: lifecycle.detail, timestamp: item.timestamp
            )
        case .modelSwitched:
            return TraceBoundary(
                id: item.id, kind: .modelSwitched,
                title: "Switched to \(lifecycle.title)",
                detail: lifecycle.detail.map { "from \($0)" },
                timestamp: item.timestamp
            )
        case .turnEnded, .failure:
            return nil
        }
    }
}
