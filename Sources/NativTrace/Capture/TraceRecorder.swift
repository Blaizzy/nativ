import Foundation
import os

public actor TraceRecorder {
    private struct PartialResponse {
        let traceID: String
        let scope: TraceScope
        var content = ""
        var reasoning = ""

        var isEmpty: Bool { content.isEmpty && reasoning.isEmpty }
    }

    private let store: TraceStore
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "dev.local.NativTrace", category: "recorder")

    private var partials: [TraceCallKey: PartialResponse] = [:]

    public init(store: TraceStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        traceID: String,
        scope: TraceScope
    ) async {
        guard let json = encode(payload) else { return }
        await record(kind: Payload.kind, json: json, traceID: traceID, scope: scope)
    }

    public func record(
        kind: TraceEventKind,
        json: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) async {
        if kind.sealsStreamedOutput {
            await flushPartials(inTrace: traceID)
        }
        await write(kind: kind, json: json, traceID: traceID, scope: scope)
    }

    public func appendDelta(
        content: String? = nil,
        reasoning: String? = nil,
        traceID: String,
        scope: TraceScope
    ) {
        guard content?.isEmpty == false || reasoning?.isEmpty == false else { return }
        let key = TraceCallKey(traceID: traceID, scope: scope)
        var partial = partials[key] ?? PartialResponse(traceID: traceID, scope: scope)
        partial.content += content ?? ""
        partial.reasoning += reasoning ?? ""
        partials[key] = partial
    }

    public func discardPartial(traceID: String, scope: TraceScope) {
        partials.removeValue(forKey: TraceCallKey(traceID: traceID, scope: scope))
    }

    public func partialResponse(
        traceID: String,
        scope: TraceScope
    ) -> (content: String, reasoning: String)? {
        guard let partial = partials[TraceCallKey(traceID: traceID, scope: scope)] else { return nil }
        return (partial.content, partial.reasoning)
    }

    public func flushAll() async {
        for key in partials.keys {
            await flushPartial(for: key)
        }
    }

    @discardableResult
    public func prune(retaining window: TraceRetentionWindow) async -> Int {
        do {
            return try await store.prune(retaining: window, now: now())
        } catch {
            note(error, while: "pruning")
            return 0
        }
    }

    private func write(
        kind: TraceEventKind,
        json: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) async {
        do {
            try await store.record(
                kind: kind, payload: json, traceID: traceID, scope: scope, timestamp: now()
            )
        } catch {
            note(error, while: "appending \(kind.rawValue)")
        }
    }

    private func flushPartials(inTrace traceID: String) async {
        for (key, partial) in partials where partial.traceID == traceID {
            await flushPartial(for: key)
        }
    }

    private func flushPartial(for key: TraceCallKey) async {
        guard let partial = partials.removeValue(forKey: key),
              !partial.isEmpty,
              let json = encode(ResponseDeltaPayload(
                  content: partial.content.isEmpty ? nil : partial.content,
                  reasoning: partial.reasoning.isEmpty ? nil : partial.reasoning
              ))
        else { return }

        await write(kind: .responseDelta, json: json, traceID: partial.traceID, scope: partial.scope)
    }

    private func encode<Payload: Encodable>(_ payload: Payload) -> TraceJSON? {
        do {
            return try TraceJSON(encoding: payload)
        } catch {
            note(error, while: "encoding a payload")
            return nil
        }
    }

    public func noteEncodeFailure(kind: TraceEventKind, message: String) {
        logger.error(
            "trace payload could not be encoded for \(kind.rawValue, privacy: .public): \(message, privacy: .public)"
        )
    }

    private func note(_ error: Error, while activity: String) {
        logger.error(
            "trace recording failed while \(activity, privacy: .public): \(String(describing: error), privacy: .public)"
        )
    }
}

struct TraceCallKey: Hashable, Sendable {
    private let value: String

    init(traceID: String, scope: TraceScope) {
        if let requestID = scope.requestID {
            value = "r:\(requestID)"
        } else {
            value = "t:\(traceID):\(scope.turnID ?? "-")"
        }
    }
}
