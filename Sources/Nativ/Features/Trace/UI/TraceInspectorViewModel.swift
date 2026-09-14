import Foundation
import NativTrace
import SwiftUI

struct TraceCall: Identifiable, Hashable {
    let id: String
    let title: String
    let timestamp: Date
    let exposure: RequestComposedPayload
    let diff: TraceExposureDiff

    var toolCount: Int { exposure.tools.count }
    var advertisesTools: Bool { exposure.advertisesTools }
}

struct TraceInstance: Identifiable, Hashable {
    let id: String
    let modelIDs: [String]
    let eventCount: Int
    let blocks: [TraceDisplayBlock]
    let calls: [TraceCall]
    let inheritedContext: [TraceMessageRef]

    var modelLabel: String {
        switch modelIDs.count {
        case 0: "Unknown model"
        case 1: modelIDs[0]
        default: "\(modelIDs.count) models used"
        }
    }
}

@MainActor
final class TraceInspectorViewModel: ObservableObject {
    @Published private(set) var instances: [TraceInstance] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published var selectedCallID: String?
    @Published var selectedInstanceID: String? {
        didSet {
            guard selectedInstanceID != oldValue else { return }
            selectLastCallIfStale()
        }
    }

    private var callsByItemID: [String: TraceCall] = [:]
    private let injectedStore: TraceStore?

    init(store: TraceStore? = nil) {
        injectedStore = store
    }

    var isEmpty: Bool { instances.isEmpty && !isLoading }

    var selectedInstance: TraceInstance? {
        instances.first { $0.id == selectedInstanceID } ?? instances.last
    }

    var blocks: [TraceDisplayBlock] { selectedInstance?.blocks ?? [] }
    var calls: [TraceCall] { selectedInstance?.calls ?? [] }
    var eventCount: Int { selectedInstance?.eventCount ?? 0 }

    func call(for itemID: String) -> TraceCall? { callsByItemID[itemID] }

    func loadSession(_ sessionID: UUID) async {
        await load { store in
            let events = try await store.events(forSession: sessionID.uuidString)
            return events.isEmpty ? [] : [events]
        }
    }

    private func load(_ fetch: (TraceStore) async throws -> [[TraceEvent]]) async {
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

    private func apply(_ traces: [[TraceEvent]]) {
        let itemsByTrace = traces.map(TraceReducer.items(for:))
        let folded = traces.indices.map { offset -> TraceInstance in
            let events = traces[offset]
            let items = itemsByTrace[offset]
            let exposures = items.compactMap { item -> (TraceItem, RequestComposedPayload)? in
                guard case .exposure(let payload) = item.body else { return nil }
                return (item, payload)
            }

            let calls = exposures.enumerated().map { position, entry -> TraceCall in
                let (item, payload) = entry
                return TraceCall(
                    id: item.id,
                    title: TraceCallLabel.title(index: position + 1, round: item.scope.roundIndex),
                    timestamp: item.timestamp,
                    exposure: payload,
                    diff: .between(position > 0 ? exposures[position - 1].1 : nil, and: payload)
                )
            }

            let produced = Set(items.compactMap { item -> String? in
                switch item.body {
                case .message(let message): message.messageID
                case .tool(let tool): tool.callID
                default: nil
                }
            })
            let inherited = (exposures.first?.1.messages ?? [])
                .filter { !produced.contains($0.messageID) }

            return TraceInstance(
                id: events.first?.traceID ?? "",
                modelIDs: Array(Set(events.compactMap { $0.scope.modelID })).sorted(),
                eventCount: events.count,
                blocks: TraceGrouping.blocks(for: items),
                calls: calls,
                inheritedContext: inherited
            )
        }

        callsByItemID = Dictionary(
            folded.flatMap(\.calls).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        instances = folded

        if !instances.contains(where: { $0.id == selectedInstanceID }) {
            selectedInstanceID = instances.last?.id
        }
        selectLastCallIfStale()
    }

    private func selectLastCallIfStale() {
        let calls = selectedInstance?.calls ?? []
        guard !calls.contains(where: { $0.id == selectedCallID }) else { return }
        selectedCallID = calls.last?.id
    }
}
