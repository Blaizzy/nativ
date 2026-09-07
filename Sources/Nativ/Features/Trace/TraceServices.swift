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
    private var lastAppliedRetention: TraceRetentionWindow?

    /// The store factory is injectable so a test can point at a temporary file
    /// instead of the user's real trace history.
    init(makeStore: @escaping () throws -> TraceStore = { try TraceStore() }) {
        self.makeStore = makeStore
    }

    /// Idempotent. Safe to call from every view that wants a producer.
    ///
    /// Deliberately does not prune. Retention is a user setting, and a sweep
    /// triggered here would run with whatever window the first caller happened
    /// to pass — which is how opening the inspector used to consume the one
    /// sweep per launch and discard the configured window.
    @discardableResult
    func start() -> ChatTraceProducer? {
        if let producer { return producer }

        guard let store = openStore() else { return nil }
        let recorder = TraceRecorder(store: store)
        let producer = ChatTraceProducer(recorder: recorder)
        self.recorder = recorder
        self.producer = producer
        return producer
    }

    /// The producer to record with, or nil when recording is off.
    ///
    /// Call whenever the setting may have changed, not only once: leaving a
    /// stale producer attached is the difference between "recording off" and
    /// "the toggle looks off".
    ///
    /// Does not tear the shared producer down. Callers cache the reference, and
    /// one caller answering "off" must not invalidate it for another that is
    /// still recording — a routine run would otherwise detach the chat.
    func producer(enabled: Bool) -> ChatTraceProducer? {
        enabled ? start() : nil
    }

    /// Applies a retention window now. Runs at most once per distinct window
    /// per launch, so repeated view appearances do not re-sweep.
    func applyRetention(_ window: TraceRetentionWindow) {
        guard window != lastAppliedRetention, let store = openStore() else { return }
        lastAppliedRetention = window
        // Goes straight to the store: a sweep has to happen when recording is
        // off too, and that is exactly when there is no producer to queue it on.
        Task { try? await store.prune(retaining: window) }
    }

    /// Opens the store if it is not open yet, without creating a producer.
    private func openStore() -> TraceStore? {
        if let store { return store }
        do {
            store = try makeStore()
        } catch {
            logger.error("trace store unavailable; recording disabled")
        }
        return store
    }

    /// Read side for the panel's trace pane and the dashboard.
    func readableStore() -> TraceStore? {
        openStore()
    }

    /// Seals open calls and flushes queued events. Called at app termination.
    func shutDown() async {
        await producer?.shutDown()
    }

    /// Termination is synchronous, so this blocks briefly for the queue to
    /// drain. Safe because the queue's consumer runs on the global executor,
    /// not the main actor — the thread being held here is not the one that has
    /// to make progress.
    func shutDownBeforeTermination(timeout: TimeInterval = 1.5) {
        guard let producer else { return }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await producer.shutDown()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timeout)
    }

    func stop() {
        producer = nil
        recorder = nil
        store = nil
    }
}

extension NativSettings {
    /// Retention derived from settings.
    ///
    /// Recording off means keep nothing, so turning it off also clears what is
    /// already on disk. A retention field left at zero means no limit of that
    /// kind, which is what the field's own label says.
    var traceRetentionWindow: TraceRetentionWindow {
        guard traceRecordingEnabled else { return .clearAll }
        return TraceRetentionWindow(
            days: traceRetentionDays == 0 ? nil : traceRetentionDays,
            maximumTraces: traceMaximumTraces == 0 ? nil : traceMaximumTraces
        )
    }
}
