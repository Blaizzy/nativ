import Foundation
import NativTrace
import SwiftUI

/// One model call, as the inspector's sidebar presents it.
struct TraceCallSummary: Identifiable, Hashable {
    let id: String
    let round: Int?
    let modelID: String?
    let timestamp: Date
    let toolCount: Int
    let advertisesTools: Bool
    let diff: TraceExposureDiff

    var title: String { TraceCallLabel.title(round: round) }
}

/// Loads a trace and folds it into something renderable.
///
/// The view owns no trace logic: it renders `blocks` and asks for the exposure
/// belonging to a row. Folding, resolution, and diffing all happen here so the
/// same work is not repeated per frame — SwiftUI will call `body` far more often
/// than the trace changes.
@MainActor
final class TraceInspectorViewModel: ObservableObject {
    @Published private(set) var blocks: [TraceDisplayBlock] = []
    @Published private(set) var calls: [TraceCallSummary] = []
    @Published private(set) var eventCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published var selectedCallID: String?

    private var exposuresByItemID: [String: ResolvedExposure] = [:]
    private var diffsByItemID: [String: TraceExposureDiff] = [:]
    private let injectedStore: TraceStore?

    /// The store is injectable so the smoke test drives this exact type rather
    /// than a parallel copy of its logic.
    init(store: TraceStore? = nil) {
        injectedStore = store
    }

    var isEmpty: Bool { blocks.isEmpty && !isLoading }

    func loadSession(_ sessionID: UUID) async {
        await load { store in
            try await store.events(forSession: sessionID.uuidString)
        }
    }

    func loadRequest(_ requestID: String) async {
        await load { store in
            try await store.events(forRequest: requestID)
        }
    }

    /// Resolved exposure for an exposure row, or `nil` for any other row.
    func exposure(for itemID: String) -> ResolvedExposure? {
        exposuresByItemID[itemID]
    }

    /// What changed relative to the previous call in the same trace.
    func diff(for itemID: String) -> TraceExposureDiff {
        diffsByItemID[itemID] ?? .none
    }

    private func load(
        _ fetch: @escaping (TraceStore) async throws -> [TraceEvent]
    ) async {
        guard let store = injectedStore ?? TraceServices.shared.readableStore() else {
            loadFailure = "Trace storage is unavailable."
            return
        }

        isLoading = true
        loadFailure = nil
        defer { isLoading = false }

        do {
            let events = try await fetch(store)
            apply(events)
        } catch {
            loadFailure = String(describing: error)
        }
    }

    private func apply(_ events: [TraceEvent]) {
        let items = TraceReducer.items(for: events)
        let index = TraceExposureIndex(items: items)

        var exposures: [String: ResolvedExposure] = [:]
        var diffs: [String: TraceExposureDiff] = [:]
        var summaries: [TraceCallSummary] = []
        var previous: RequestComposedPayload?

        for item in items {
            guard case .exposure(let payload) = item.body else { continue }
            let diff = TraceExposureDiff.between(previous, and: payload)
            exposures[item.id] = index.resolve(payload)
            diffs[item.id] = diff
            summaries.append(
                TraceCallSummary(
                    id: item.id,
                    round: item.scope.roundIndex,
                    modelID: item.scope.modelID,
                    timestamp: item.timestamp,
                    toolCount: payload.tools.count,
                    advertisesTools: payload.advertisesTools,
                    diff: diff
                )
            )
            previous = payload
        }

        eventCount = events.count
        exposuresByItemID = exposures
        diffsByItemID = diffs
        calls = summaries
        blocks = TraceGrouping.blocks(for: items)
        let selectionSurvived = selectedCallID.map { exposures[$0] != nil } ?? false
        if !selectionSurvived {
            selectedCallID = summaries.last?.id
        }
    }
}
