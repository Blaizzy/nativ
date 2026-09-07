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
    /// Either work to run against the recorder, or a barrier to resume once
    /// everything ahead of it has run. Carrying a closure rather than a case
    /// per method keeps one signature per operation instead of three.
    private enum Job: Sendable {
        case run(@Sendable (TraceRecorder) async -> Void)
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
                case .run(let work): await work(recorder)
                case .barrier(let continuation): continuation.resume()
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
        continuation.yield(.run {
            await $0.record(kind: kind, json: payload, traceID: traceID, scope: scope)
        })
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
            let message = String(describing: error)
            continuation.yield(.run {
                await $0.noteEncodeFailure(kind: Payload.kind, message: message)
            })
        }
    }

    public func delta(
        content: String?,
        reasoning: String?,
        traceID: String,
        scope: TraceScope
    ) {
        continuation.yield(.run {
            await $0.appendDelta(
                content: content, reasoning: reasoning, traceID: traceID, scope: scope
            )
        })
    }

    public func discardPartial(traceID: String, scope: TraceScope) {
        continuation.yield(.run { await $0.discardPartial(traceID: traceID, scope: scope) })
    }

    public func prune(retaining window: TraceRetentionWindow) {
        continuation.yield(.run { await $0.prune(retaining: window) })
    }

    /// Seals every call still streaming. For shutdown, where the accumulated
    /// output is the only record of a call that will never complete.
    public func flushAll() {
        continuation.yield(.run { await $0.flushAll() })
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
