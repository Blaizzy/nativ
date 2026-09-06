import Foundation
import NativTrace
import os

/// Composition root for tracing.
///
/// Owns the one store and the one recorder for the process, and hands out the
/// producer that feature code talks to. Kept out of `NativTrace` so the
/// framework has no opinion about app lifetime, and kept to one instance so two
/// writers can never open the same database and interleave sequence numbers.
///
/// If the store cannot be opened, `producer` stays nil and every call site
/// no-ops. A trace that fails to record must never be able to break a chat.
@MainActor
final class TraceServices {
    static let shared = TraceServices()

    private let logger = Logger(subsystem: "dev.local.Nativ", category: "trace")
    private let makeStore: () throws -> TraceStore
    private var store: TraceStore?
    private var recorder: TraceRecorder?
    private(set) var producer: ChatTraceProducer?
    private var hasPruned = false

    /// The store factory is injectable so a test can point at a temporary file
    /// instead of the user's real trace history.
    init(makeStore: @escaping () throws -> TraceStore = { try TraceStore() }) {
        self.makeStore = makeStore
    }

    /// Idempotent. Safe to call from every view that wants a producer.
    @discardableResult
    func start(retention: TraceRetentionWindow = .default) -> ChatTraceProducer? {
        if let producer { return producer }

        do {
            let store = try makeStore()
            let recorder = TraceRecorder(store: store)
            let producer = ChatTraceProducer(recorder: recorder)
            self.store = store
            self.recorder = recorder
            self.producer = producer

            if !hasPruned {
                hasPruned = true
                producer.prune(retaining: retention)
            }
            return producer
        } catch {
            logger.error("trace store unavailable; recording disabled")
            return nil
        }
    }

    /// Read side for the dashboard and the chat inspector.
    func readableStore() -> TraceStore? {
        start()
        return store
    }

    func stop() {
        producer = nil
        recorder = nil
        store = nil
    }
}

extension NativSettings {
    /// Retention derived from settings. Recording off means keep nothing, so
    /// turning it off also clears what is already on disk on the next sweep.
    var traceRetentionWindow: TraceRetentionWindow {
        guard traceRecordingEnabled else { return .none }
        return TraceRetentionWindow(
            days: traceRetentionDays == 0 ? nil : traceRetentionDays,
            maximumTraces: traceMaximumTraces == 0 ? nil : traceMaximumTraces
        )
    }
}
