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

    private var partials: [String: PartialResponse] = [:]

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
        if Payload.kind.sealsStreamedOutput {
            await flushPartials(inTrace: traceID)
        }
        await write(kind: Payload.kind, json: json, traceID: traceID, scope: scope)
    }

    public func appendDelta(
        content: String? = nil,
        reasoning: String? = nil,
        traceID: String,
        scope: TraceScope
    ) {
        guard content?.isEmpty == false || reasoning?.isEmpty == false else { return }
        let key = partialKey(traceID: traceID, scope: scope)
        var partial = partials[key] ?? PartialResponse(traceID: traceID, scope: scope)
        partial.content += content ?? ""
        partial.reasoning += reasoning ?? ""
        partials[key] = partial
    }

    public func discardPartial(traceID: String, scope: TraceScope) {
        partials.removeValue(forKey: partialKey(traceID: traceID, scope: scope))
    }

    public func flushAll() async {
        for key in partials.keys {
            await flushPartial(for: key)
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

    private func flushPartial(for key: String) async {
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

    private func note(_ error: Error, while activity: String) {
        logger.error(
            "trace recording failed while \(activity, privacy: .public): \(String(describing: error), privacy: .public)"
        )
    }

    private func partialKey(traceID: String, scope: TraceScope) -> String {
        scope.requestID.map { "r:\($0)" } ?? "t:\(traceID):\(scope.turnID ?? "-")"
    }
}
