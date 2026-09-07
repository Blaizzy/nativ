import Foundation
import NativTrace
import SwiftUI

/// One model call, as the inspector's sidebar presents it.
struct TraceCallSummary: Identifiable, Hashable {
    let id: String
    /// The call's request id, used to select the call a dashboard row refers to.
    let requestID: String?
    let round: Int?
    let modelID: String?
    let timestamp: Date
    let toolCount: Int
    let advertisesTools: Bool
    let diff: TraceExposureDiff
    /// Position of this call within its trace, one-based.
    let index: Int

    var title: String { TraceCallLabel.title(index: index, round: round) }
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
    /// Conversation this model was handed but did not produce.
    ///
    /// A model that takes over a chat is shown everything that came before, and
    /// its first exposure records all of it. Surfacing it here lets the trace
    /// read as a complete account of what this instance saw, instead of opening
    /// with an answer to a question it appears never to have been asked.
    let inheritedContext: [ResolvedMessage]
    /// Model this instance took over from, when it took over from one.
    let precedingModelID: String?

    var modelLabel: String { modelID ?? "Unknown model" }
}

@MainActor
final class TraceInspectorViewModel: ObservableObject {
    @Published private(set) var instances: [TraceInstance] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published var selectedInstanceID: String?
    @Published var selectedCallID: String?

    /// Request whose call should be selected once loading finishes.
    private var pendingCallSelection: String?
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

    /// One call, for the dashboard, read in the context of its trace.
    ///
    /// Reading only the events whose `request_id` matches would exclude the
    /// turn's prompt — which has no request id — leaving a transcript with an
    /// answer and no question and nothing for the exposure to resolve against.
    func loadRequest(_ requestID: String) async {
        pendingCallSelection = requestID
        await load { store in
            let matching = try await store.events(forRequest: requestID)
            guard let first = matching.first else { return [] }
            let events = try await store.events(forTrace: first.traceID)
            return [(
                TraceSummary(
                    traceID: first.traceID,
                    sessionID: first.scope.sessionID,
                    startedAt: events.first?.timestamp ?? first.timestamp,
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

    /// Label for an exposure row, numbered within its trace rather than by the
    /// per-turn round index.
    func callLabel(for itemID: String) -> String {
        instances
            .lazy
            .flatMap(\.calls)
            .first { $0.id == itemID }?
            .title ?? "Model call"
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

        let folded = traces.indices.map { offset -> TraceInstance in
            let (summary, events) = traces[offset]
            let items = foldedItems[offset]
            var previous: RequestComposedPayload?
            var firstExposure: RequestComposedPayload?
            var callIndex = 0
            var calls: [TraceCallSummary] = []

            for item in items {
                guard case .exposure(let payload) = item.body else { continue }
                // Diffs stay within one trace: comparing a call to the last
                // call of a different model would report the whole exposure as
                // changed, which is true and useless.
                let diff = TraceExposureDiff.between(previous, and: payload)
                if firstExposure == nil { firstExposure = payload }
                exposures[item.id] = index.resolve(payload)
                diffs[item.id] = diff
                callIndex += 1
                calls.append(
                    TraceCallSummary(
                        id: item.id,
                        requestID: item.scope.requestID,
                        round: item.scope.roundIndex,
                        modelID: item.scope.modelID,
                        timestamp: item.timestamp,
                        toolCount: payload.tools.count,
                        advertisesTools: payload.advertisesTools,
                        diff: diff,
                        index: callIndex
                    )
                )
                previous = payload
            }

            // Anything the first call was shown but this trace never recorded
            // came from whoever served the chat before it.
            let produced = Set(items.compactMap { item -> String? in
                switch item.body {
                case .message(let message): message.messageID
                case .tool(let tool): tool.callID
                default: nil
                }
            })
            let inherited = (firstExposure?.messages ?? [])
                .filter { !produced.contains($0.messageID) }
                .map { index.resolve(RequestComposedPayload(messages: [$0])).messages[0] }

            return TraceInstance(
                id: summary.traceID,
                modelID: summary.modelIDs.first,
                startedAt: summary.startedAt,
                eventCount: events.count,
                blocks: TraceGrouping.blocks(for: items),
                calls: calls,
                inheritedContext: inherited,
                precedingModelID: offset > 0 ? traces[offset - 1].0.modelIDs.first : nil
            )
        }

        exposuresByItemID = exposures
        diffsByItemID = diffs
        instances = folded

        if selectedInstanceID == nil || !folded.contains(where: { $0.id == selectedInstanceID }) {
            selectedInstanceID = folded.last?.id
        }
        if let requested = pendingCallSelection {
            pendingCallSelection = nil
            let calls = folded.flatMap(\.calls)
            if let match = calls.first(where: { $0.requestID == requested }) ?? calls.last {
                selectedInstanceID = folded.first { $0.calls.contains(match) }?.id ?? selectedInstanceID
                selectedCallID = match.id
                return
            }
        }

        let survived = selectedCallID.map { exposures[$0] != nil } ?? false
        if !survived {
            selectedCallID = selectedInstance?.calls.last?.id
        }
    }
}
