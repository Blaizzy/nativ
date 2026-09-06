import Foundation
import os

/// The only writer producers talk to.
///
/// Owns three things producers should not have to think about: sequence
/// allocation, keeping a token stream from becoming a row per token, and never
/// letting a recording failure reach the feature being recorded.
///
/// ## Streaming
///
/// A model call emits thousands of deltas and one completion, and the
/// completion carries the authoritative text. Persisting every delta would make
/// a trace mostly redundant chaff, so deltas accumulate in memory and are
/// written only if the call never completes — a cancel or a crash, where the
/// partial output is the only record of what happened. A completed call costs
/// one row.
public actor TraceRecorder {
    private let store: TraceStore
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "dev.local.NativTrace", category: "recorder")

    private struct PartialResponse {
        var traceID: String
        var scope: TraceScope
        var content: String = ""
        var reasoning: String = ""

        var isEmpty: Bool { content.isEmpty && reasoning.isEmpty }
    }

    private var partials: [String: PartialResponse] = [:]
    private var failureCount = 0

    /// Last recording failure, for diagnostics. Recording never throws into a
    /// producer: a broken trace must not break a chat.
    public private(set) var lastError: String?

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
        await record(kind: Payload.kind, payload: payload, traceID: traceID, scope: scope)
    }

    /// Escape hatch for producers with a payload that is not a `TracePayloadView`,
    /// such as a wire body captured verbatim.
    public func record(
        kind: TraceEventKind,
        json: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) async {
        await write(kind: kind, payload: json, traceID: traceID, scope: scope)
    }

    private func record<Payload: Encodable>(
        kind: TraceEventKind,
        payload: Payload,
        traceID: String,
        scope: TraceScope
    ) async {
        do {
            await write(kind: kind, payload: try TraceJSON(encoding: payload), traceID: traceID, scope: scope)
        } catch {
            note(error, while: "encoding \(kind.rawValue)")
        }
    }

    private func write(
        kind: TraceEventKind,
        payload: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) async {
        await flushPartial(key: callKey(traceID: traceID, scope: scope), reason: kind)
        await append(kind: kind, payload: payload, traceID: traceID, scope: scope)
    }

    private func append(
        kind: TraceEventKind,
        payload: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) async {
        do {
            let seq = try await store.reserveSequence(forTrace: traceID)
            try await store.append(
                TraceEvent(
                    traceID: traceID,
                    seq: seq,
                    timestamp: now(),
                    kind: kind,
                    scope: scope,
                    payload: payload
                )
            )
        } catch {
            note(error, while: "appending \(kind.rawValue)")
        }
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
        let key = callKey(traceID: traceID, scope: scope)
        var partial = partials[key] ?? PartialResponse(traceID: traceID, scope: scope)
        partial.content += content ?? ""
        partial.reasoning += reasoning ?? ""
        partials[key] = partial
    }

    /// Discards the accumulated stream, because the completion event about to be
    /// recorded supersedes it.
    public func discardPartial(traceID: String, scope: TraceScope) {
        partials.removeValue(forKey: callKey(traceID: traceID, scope: scope))
    }

    /// Text streamed for a call that has not been sealed yet, for a live view.
    public func partialResponse(traceID: String, scope: TraceScope) -> (content: String, reasoning: String)? {
        guard let partial = partials[callKey(traceID: traceID, scope: scope)] else { return nil }
        return (partial.content, partial.reasoning)
    }

    /// Writes accumulated stream text as one delta row, so a call that never
    /// completed still shows what the model had produced.
    private func flushPartial(key: String, reason: TraceEventKind) async {
        guard reason != .responseDelta, let partial = partials.removeValue(forKey: key) else { return }
        guard !partial.isEmpty else { return }
        do {
            let payload = try ResponseDeltaPayload(
                content: partial.content.isEmpty ? nil : partial.content,
                reasoning: partial.reasoning.isEmpty ? nil : partial.reasoning
            ).makePayload()
            await append(
                kind: .responseDelta,
                payload: payload,
                traceID: partial.traceID,
                scope: partial.scope
            )
        } catch {
            note(error, while: "flushing partial response")
        }
    }

    /// Seals every open call. Call when a session closes or the app is quitting.
    public func flushAll() async {
        for key in partials.keys {
            await flushPartial(key: key, reason: .responseFailed)
        }
    }

    // MARK: - Retention

    @discardableResult
    public func prune(retaining window: TraceRetentionWindow) async -> Int {
        do {
            return try await store.prune(
                before: window.cutoff(from: now()),
                maxTraces: window.maximumTraces
            )
        } catch {
            note(error, while: "pruning")
            return 0
        }
    }

    // MARK: - Internals

    private func callKey(traceID: String, scope: TraceScope) -> String {
        if let requestID = scope.requestID { return "r:\(requestID)" }
        return "t:\(traceID):\(scope.turnID ?? "-")"
    }

    private func note(_ error: Error, while activity: String) {
        failureCount += 1
        lastError = "\(activity): \(error)"
        logger.error("trace recording failed while \(activity, privacy: .public)")
    }

    public var recordingFailureCount: Int { failureCount }
}

/// How much history to keep.
public struct TraceRetentionWindow: Sendable, Hashable {
    public var days: Int?
    public var maximumTraces: Int?

    public static let `default` = TraceRetentionWindow(days: 30, maximumTraces: 500)
    /// Keeps nothing; used when the user turns recording off and clears history.
    public static let none = TraceRetentionWindow(days: 0, maximumTraces: 0)

    public init(days: Int?, maximumTraces: Int?) {
        self.days = days
        self.maximumTraces = maximumTraces
    }

    public func cutoff(from reference: Date) -> Date {
        guard let days else { return .distantPast }
        return reference.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}
