import Foundation
import NativTrace
import SwiftUI

struct TraceCall: Identifiable, Hashable {
    let id: String
    let requestID: String?
    let title: String
    let timestamp: Date
    let diff: TraceExposureDiff
    let exposure: ResolvedExposure

    var toolCount: Int { exposure.tools.count }
    var advertisesTools: Bool { exposure.advertisesTools }
}

struct TraceInstance: Identifiable, Hashable {
    let id: String
    let modelID: String?
    let eventCount: Int
    let blocks: [TraceDisplayBlock]
    let calls: [TraceCall]
    let inheritedContext: [ResolvedMessage]
    let precedingModelID: String?

    var modelLabel: String { modelID ?? "Unknown model" }
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

    private var pendingRequestSelection: String?
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
            Self.grouped(try await store.events(forSession: sessionID.uuidString))
        }
    }

    func loadRequest(_ requestID: String) async {
        pendingRequestSelection = requestID
        await load { store in
            guard let event = try await store.events(forRequest: requestID).first else { return [] }
            return [try await store.events(forTrace: event.traceID)]
        }
    }

    private static func grouped(_ events: [TraceEvent]) -> [[TraceEvent]] {
        var order: [String] = []
        var byTrace: [String: [TraceEvent]] = [:]
        for event in events {
            if byTrace[event.traceID] == nil { order.append(event.traceID) }
            byTrace[event.traceID, default: []].append(event)
        }
        return order.compactMap { byTrace[$0] }
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
        let index = TraceExposureIndex(items: itemsByTrace.flatMap { $0 })

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
                    requestID: item.scope.requestID,
                    title: TraceCallLabel.title(index: position + 1, round: item.scope.roundIndex),
                    timestamp: item.timestamp,
                    diff: .between(position > 0 ? exposures[position - 1].1 : nil, and: payload),
                    exposure: index.resolve(payload)
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
                .map { index.resolve($0) }

            return TraceInstance(
                id: events.first?.traceID ?? "",
                modelID: events.first?.scope.modelID,
                eventCount: events.count,
                blocks: TraceGrouping.blocks(for: items),
                calls: calls,
                inheritedContext: inherited,
                precedingModelID: offset > 0 ? traces[offset - 1].first?.scope.modelID : nil
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
        if let requested = pendingRequestSelection {
            pendingRequestSelection = nil
            for instance in instances {
                guard let match = instance.calls.first(where: { $0.requestID == requested })
                else { continue }
                selectedInstanceID = instance.id
                selectedCallID = match.id
                return
            }
        }
        selectLastCallIfStale()
    }

    private func selectLastCallIfStale() {
        let calls = selectedInstance?.calls ?? []
        guard !calls.contains(where: { $0.id == selectedCallID }) else { return }
        selectedCallID = calls.last?.id
    }
}
