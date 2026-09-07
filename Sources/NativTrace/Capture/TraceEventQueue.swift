import Foundation

/// Hands events to a `TraceRecorder` without blocking the caller and without
/// reordering them.
///
/// Producers run on whatever actor their feature runs on — the main actor, for
/// chat — and must not wait on a database write. Firing a detached `Task` per
/// event would achieve that and quietly break ordering: independent tasks reach
/// an actor in whatever order the scheduler picks, so a tool result can be
/// written before the call it answers. One unbounded stream drained by one
/// consumer gives both properties.
///
/// Lives in the framework rather than in a feature because every producer needs
/// it — chat today, the local server later — and because the ordering guarantee
/// is worth a test that does not require building the app.
public final class TraceEventQueue: Sendable {
    private enum Job: Sendable {
        case record(kind: TraceEventKind, payload: TraceJSON, traceID: String, scope: TraceScope)
        case delta(content: String?, reasoning: String?, traceID: String, scope: TraceScope)
        case discardPartial(traceID: String, scope: TraceScope)
        case prune(TraceRetentionWindow)
        case flushAll
        case encodeFailure(kind: TraceEventKind, message: String)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Job>.Continuation
    private let pump: Task<Void, Never>

    public init(recorder: TraceRecorder) {
        let (stream, continuation) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        pump = Task {
            for await job in stream {
                switch job {
                case .record(let kind, let payload, let traceID, let scope):
                    await recorder.record(kind: kind, json: payload, traceID: traceID, scope: scope)
                case .delta(let content, let reasoning, let traceID, let scope):
                    await recorder.appendDelta(
                        content: content, reasoning: reasoning, traceID: traceID, scope: scope
                    )
                case .discardPartial(let traceID, let scope):
                    await recorder.discardPartial(traceID: traceID, scope: scope)
                case .prune(let window):
                    await recorder.prune(retaining: window)
                case .flushAll:
                    await recorder.flushAll()
                case .encodeFailure(let kind, let message):
                    await recorder.noteEncodeFailure(kind: kind, message: message)
                case .barrier(let continuation):
                    continuation.resume()
                }
            }
        }
    }

    deinit {
        continuation.finish()
    }

    public func record(
        kind: TraceEventKind,
        payload: TraceJSON,
        traceID: String,
        scope: TraceScope
    ) {
        continuation.yield(.record(kind: kind, payload: payload, traceID: traceID, scope: scope))
    }

    public func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        traceID: String,
        scope: TraceScope
    ) {
        do {
            let json = try TraceJSON(encoding: payload)
            record(kind: Payload.kind, payload: json, traceID: traceID, scope: scope)
        } catch {
            // Counted rather than discarded: a payload that cannot be encoded
            // is a missing row, and a silently shorter trace is the failure this
            // design is meant to make impossible.
            continuation.yield(.encodeFailure(kind: Payload.kind, message: String(describing: error)))
        }
    }

    public func delta(
        content: String?,
        reasoning: String?,
        traceID: String,
        scope: TraceScope
    ) {
        continuation.yield(.delta(
            content: content, reasoning: reasoning, traceID: traceID, scope: scope
        ))
    }

    public func discardPartial(traceID: String, scope: TraceScope) {
        continuation.yield(.discardPartial(traceID: traceID, scope: scope))
    }

    public func prune(retaining window: TraceRetentionWindow) {
        continuation.yield(.prune(window))
    }

    /// Seals every call still streaming. For shutdown, where the accumulated
    /// output is the only record of a call that will never complete.
    public func flushAll() {
        continuation.yield(.flushAll)
    }

    /// Waits until everything queued so far has reached the recorder.
    ///
    /// For tests and for shutdown. Ordinary recording never waits.
    public func drain() async {
        await withCheckedContinuation { continuation in
            self.continuation.yield(.barrier(continuation))
        }
    }
}
