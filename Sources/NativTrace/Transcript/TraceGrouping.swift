import Foundation

/// A run of consecutive tool rows, collapsed behind one summary line.
public struct TraceToolRun: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let items: [TraceItem]

    public var count: Int { items.count }
}

public enum TraceTurnSegment: Sendable, Hashable, Identifiable {
    case item(TraceItem)
    case toolRun(TraceToolRun)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .toolRun(let run): run.id
        }
    }
}

/// One user prompt and everything the model did in response.
public struct TraceTurn: Sendable, Hashable, Identifiable {
    public let id: String
    public let prompt: TraceItem?
    public let segments: [TraceTurnSegment]
    public let startedAt: Date

    /// Exposures in this turn, oldest first — one per model call.
    public var calls: [TraceItem] {
        segments.compactMap { segment in
            guard case .item(let item) = segment, case .exposure = item.body else { return nil }
            return item
        }
    }
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
/// Kept separate from `TraceReducer` because these are display choices —
/// how many tool rows to collapse, where to draw a divider — and they must not
/// leak into the semantic layer. Changing a grouping rule can never lose an
/// item; every input item appears in exactly one output block.
public enum TraceGrouping {
    /// Runs shorter than this stay expanded; collapsing two rows hides more
    /// than it saves.
    public static let minimumCollapsedRun = 3

    public static func blocks(for items: [TraceItem]) -> [TraceDisplayBlock] {
        var blocks: [TraceDisplayBlock] = []
        var currentTurnID: String?
        var currentPrompt: TraceItem?
        var currentSegments: [TraceItem] = []

        func flushTurn() {
            guard currentPrompt != nil || !currentSegments.isEmpty else { return }
            let turn = TraceTurn(
                id: currentTurnID ?? currentPrompt?.id ?? currentSegments.first?.id ?? UUID().uuidString,
                prompt: currentPrompt,
                segments: collapseToolRuns(currentSegments),
                startedAt: currentPrompt?.timestamp ?? currentSegments.first?.timestamp ?? .distantPast
            )
            blocks.append(.turn(turn))
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

            if currentPrompt == nil && currentSegments.isEmpty && item.scope.turnID == nil {
                blocks.append(.loose(item))
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

    private static func collapseToolRuns(_ items: [TraceItem]) -> [TraceTurnSegment] {
        var segments: [TraceTurnSegment] = []
        var run: [TraceItem] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= minimumCollapsedRun {
                segments.append(.toolRun(TraceToolRun(
                    id: "run:\(run[0].id)",
                    label: label(for: run),
                    items: run
                )))
            } else {
                segments.append(contentsOf: run.map(TraceTurnSegment.item))
            }
            run = []
        }

        for item in items {
            if case .tool = item.body {
                run.append(item)
            } else {
                flushRun()
                segments.append(.item(item))
            }
        }
        flushRun()
        return segments
    }

    private static func label(for run: [TraceItem]) -> String {
        let names = run.compactMap { item -> String? in
            guard case .tool(let tool) = item.body else { return nil }
            return tool.name
        }
        let distinct = Set(names)
        if distinct.count == 1, let name = distinct.first {
            return "\(name) ×\(run.count)"
        }
        return "\(run.count) tool calls"
    }
}
