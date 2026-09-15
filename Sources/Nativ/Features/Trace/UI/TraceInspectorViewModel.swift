import Foundation
import SwiftUI

struct TraceCall: Identifiable, Hashable {
    let id: String
    let title: String
    let exposure: RequestComposedPayload
}

@MainActor
final class TraceInspectorViewModel: ObservableObject {
    @Published private(set) var modelIDs: [String] = []
    @Published private(set) var eventCount = 0
    @Published private(set) var blocks: [TraceDisplayBlock] = []
    @Published private(set) var calls: [TraceCall] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    @Published var selectedCallID: String?

    private var callsByItemID: [String: TraceCall] = [:]
    private let injectedStore: TraceStore?

    init(store: TraceStore? = nil) {
        injectedStore = store
    }

    var isEmpty: Bool { blocks.isEmpty && !isLoading }

    func call(for itemID: String) -> TraceCall? { callsByItemID[itemID] }

    func loadSession(_ sessionID: UUID) async {
        await load { store in
            let events = try await store.events(forSession: sessionID.uuidString)
            return events
        }
    }

    private func load(_ fetch: (TraceStore) async throws -> [TraceEvent]) async {
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

    private func apply(_ events: [TraceEvent]) {
        let items = TraceReducer.items(for: events)
        let exposures = items.compactMap { item -> (TraceItem, RequestComposedPayload)? in
            guard case .exposure(let payload) = item.body else { return nil }
            return (item, payload)
        }
        let chronologicalCalls = exposures.enumerated().map { position, entry in
            TraceCall(
                id: entry.0.id,
                title: TraceCallLabel.title(index: position + 1, round: entry.0.scope.roundIndex),
                exposure: entry.1
            )
        }

        modelIDs = Array(Set(events.compactMap { $0.scope.modelID })).sorted()
        eventCount = events.count
        blocks = Array(TraceGrouping.blocks(for: items).reversed())
        calls = Array(chronologicalCalls.reversed())
        callsByItemID = Dictionary(calls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selectedCallID = calls.first?.id
    }
}
