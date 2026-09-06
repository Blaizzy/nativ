import Foundation
import os

/// The writer producers talk to.
///
/// Owns the two things a producer should not have to think about: keeping a
/// token stream from becoming a row per token, and never letting a recording
/// failure reach the feature being recorded. Nothing here throws — a broken
/// trace must not break a chat — so failures are counted and logged instead.
///
/// ## Streaming
///
/// A model call emits thousands of deltas and one completion, and the
/// completion carries the authoritative text. Persisting every delta would make
/// a trace mostly chaff, so deltas accumulate in memory and reach the database
/// only if the call never completes — a cancel or a crash, where the partial
/// output is the only record of what happened. A completed call costs one row.
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

    /// Number of events that failed to record, and the most recent reason.
    /// Surfaced rather than silently swallowed so a broken trace is diagnosable.
    public private(set) var failureCount = 0
    public private(set) var lastFailure: String?

    public init(store: TraceStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    // MARK: - Recording

    public func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        traceID: String,
        scope: TraceScope
    ) async {
        guard let json = encode(payload) else { return }
        await record(kind: Payload.kind, json: json, traceID: traceID, scope: scope)
    }

    /// For payloads that are not a `TracePayloadView` — a wire body captured
    /// verbatim, or an event replayed from another producer.
    public func record(
        kind: TraceEventKind,
        json: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) async {
        await flushPartial(for: TraceCallKey(traceID: traceID, scope: scope), because: kind)
        await write(kind: kind, json: json, traceID: traceID, scope: scope)
    }

    // MARK: - Streaming

    /// Accumulates streamed output without touching the database.
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

    /// Drops the accumulated stream because the completion about to be recorded
    /// supersedes it.
    public func discardPartial(traceID: String, scope: TraceScope) {
        partials.removeValue(forKey: TraceCallKey(traceID: traceID, scope: scope))
    }

    /// Text streamed for a call that has not been sealed yet, for a live view.
    public func partialResponse(
        traceID: String,
        scope: TraceScope
    ) -> (content: String, reasoning: String)? {
        guard let partial = partials[TraceCallKey(traceID: traceID, scope: scope)] else { return nil }
        return (partial.content, partial.reasoning)
    }

    /// Seals every open call. Call when a session closes or the app is quitting.
    public func flushAll() async {
        for key in partials.keys {
            await flushPartial(for: key, because: .responseFailed)
        }
    }

    // MARK: - Retention

    @discardableResult
    public func prune(retaining window: TraceRetentionWindow) async -> Int {
        do {
            return try await store.prune(retaining: window, now: now())
        } catch {
            note(error, while: "pruning")
            return 0
        }
    }

    // MARK: - Internals

    /// Awaits the store rather than spawning a task.
    ///
    /// A detached task would return here immediately and let the next event
    /// reach the store first, which is how a tool result ends up recorded
    /// before the call it answers. Callers already serialise their own writes;
    /// this keeps that guarantee intact all the way to disk.
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

    private func flushPartial(for key: TraceCallKey, because reason: TraceEventKind) async {
        guard reason != .responseDelta,
              let partial = partials.removeValue(forKey: key),
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
        failureCount += 1
        lastFailure = "\(activity): \(error)"
        logger.error("trace recording failed while \(activity, privacy: .public)")
    }
}

/// Identity of one model call.
///
/// Streaming deltas have to find the message they belong to, and a turn can
/// have many calls. Falls back to the turn when a producer does not assign
/// request ids.
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
