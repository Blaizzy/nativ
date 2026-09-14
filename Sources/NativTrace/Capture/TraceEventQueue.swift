import Foundation

public final class TraceEventQueue: Sendable {
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

    public func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        traceID: String,
        scope: TraceScope
    ) {
        continuation.yield(.run {
            await $0.record(payload, traceID: traceID, scope: scope)
        })
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

    public func flushAll() {
        continuation.yield(.run { await $0.flushAll() })
    }

    public func drain() async {
        await withCheckedContinuation { continuation in
            self.continuation.yield(.barrier(continuation))
        }
    }
}
