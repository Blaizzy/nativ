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

/// One model's view of a chat, folded on its own.
///
/// A chat holds one of these per model that served it. They are kept separate
/// rather than merged because two models were shown different system prompts
/// and different tools; interleaving them by timestamp would produce a
/// transcript that belongs to no single model.
struct TraceInstance: Identifiable, Hashable {
    let id: String
    let modelID: String?
    let startedAt: Date
    let eventCount: Int
    let blocks: [TraceDisplayBlock]
    let calls: [TraceCallSummary]

    var modelLabel: String { modelID ?? "Unknown model" }
}

@MainActor
final class TraceInspectorViewModel: ObservableObject {
    @Published private(set) var instances: [TraceInstance] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published var selectedInstanceID: String?
    @Published var selectedCallID: String?

    private var exposuresByItemID: [String: ResolvedExposure] = [:]
    private var diffsByItemID: [String: TraceExposureDiff] = [:]
    private let injectedStore: TraceStore?

    /// The store is injectable so the smoke test drives this exact type rather
    /// than a parallel copy of its logic.
    init(store: TraceStore? = nil) {
        injectedStore = store
    }

    var isEmpty: Bool { instances.isEmpty && !isLoading }

    var selectedInstance: TraceInstance? {
        instances.first { $0.id == selectedInstanceID } ?? instances.last
    }

    var blocks: [TraceDisplayBlock] { selectedInstance?.blocks ?? [] }
    var calls: [TraceCallSummary] { selectedInstance?.calls ?? [] }
    var eventCount: Int { selectedInstance?.eventCount ?? 0 }

    /// Every trace belonging to a chat, folded separately.
    func loadSession(_ sessionID: UUID) async {
        await load { store in
            let summaries = try await store.traces(forSession: sessionID.uuidString)
            var loaded: [(TraceSummary, [TraceEvent])] = []
            for summary in summaries {
                loaded.append((summary, try await store.events(forTrace: summary.traceID)))
            }
            return loaded
        }
    }

    /// A single call, for the dashboard. Its events all belong to one trace.
    func loadRequest(_ requestID: String) async {
        await load { store in
            let events = try await store.events(forRequest: requestID)
            guard let first = events.first else { return [] }
            return [(
                TraceSummary(
                    traceID: first.traceID,
                    sessionID: first.scope.sessionID,
                    startedAt: first.timestamp,
                    lastEventAt: events.last?.timestamp ?? first.timestamp,
                    eventCount: events.count,
                    lastSeq: events.last?.seq ?? first.seq,
                    modelIDs: [first.scope.modelID].compactMap { $0 }
                ),
                events
            )]
        }
    }

    func exposure(for itemID: String) -> ResolvedExposure? {
        exposuresByItemID[itemID]
    }

    func diff(for itemID: String) -> TraceExposureDiff {
        diffsByItemID[itemID] ?? .none
    }

    private func load(
        _ fetch: @escaping (TraceStore) async throws -> [(TraceSummary, [TraceEvent])]
    ) async {
        guard let store = injectedStore ?? TraceServices.shared.readableStore() else {
            loadFailure = "Trace storage is unavailable."
            return
        }

        isLoading = true
        loadFailure = nil
        defer { isLoading = false }

        do {
            apply(try await fetch(store))
        } catch {
            loadFailure = String(describing: error)
        }
    }

    private func apply(_ traces: [(TraceSummary, [TraceEvent])]) {
        var exposures: [String: ResolvedExposure] = [:]
        var diffs: [String: TraceExposureDiff] = [:]

        let foldedItems = traces.map { TraceReducer.items(for: $0.1) }

        // Resolution spans the whole chat, folding does not. A call made after a
        // model switch references messages recorded in the previous model's
        // trace; an index built per trace cannot see them and would report the
        // entire conversation as unretained.
        let index = TraceExposureIndex(items: foldedItems.flatMap { $0 })

        let folded = zip(traces, foldedItems).map { pair, items -> TraceInstance in
            let (summary, events) = pair
            var previous: RequestComposedPayload?
            var calls: [TraceCallSummary] = []

            for item in items {
                guard case .exposure(let payload) = item.body else { continue }
                // Diffs stay within one trace: comparing a call to the last
                // call of a different model would report the whole exposure as
                // changed, which is true and useless.
                let diff = TraceExposureDiff.between(previous, and: payload)
                exposures[item.id] = index.resolve(payload)
                diffs[item.id] = diff
                calls.append(
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

            return TraceInstance(
                id: summary.traceID,
                modelID: summary.modelIDs.first,
                startedAt: summary.startedAt,
                eventCount: events.count,
                blocks: TraceGrouping.blocks(for: items),
                calls: calls
            )
        }

        exposuresByItemID = exposures
        diffsByItemID = diffs
        instances = folded

        if selectedInstanceID == nil || !folded.contains(where: { $0.id == selectedInstanceID }) {
            selectedInstanceID = folded.last?.id
        }
        let survived = selectedCallID.map { exposures[$0] != nil } ?? false
        if !survived {
            selectedCallID = selectedInstance?.calls.last?.id
        }
    }
}
