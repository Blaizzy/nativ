import Foundation
import NativTrace
import os

@MainActor
final class TraceServices {
    static let shared = TraceServices()

    private let logger = Logger(subsystem: "dev.local.Nativ", category: "trace")
    private let makeStore: () throws -> TraceStore
    private var store: TraceStore?
    private var recorder: TraceRecorder?
    private(set) var producer: ChatTraceProducer?
    private var lastAppliedRetention: TraceRetentionWindow?

    init(makeStore: @escaping () throws -> TraceStore = { try TraceStore() }) {
        self.makeStore = makeStore
    }

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

    func producer(enabled: Bool) -> ChatTraceProducer? {
        enabled ? start() : nil
    }

    func applyRetention(_ window: TraceRetentionWindow) {
        guard window != lastAppliedRetention, let store = openStore() else { return }
        lastAppliedRetention = window
        Task { try? await store.prune(retaining: window) }
    }

    private func openStore() -> TraceStore? {
        if let store { return store }
        do {
            store = try makeStore()
        } catch {
            logger.error("trace store unavailable; recording disabled")
        }
        return store
    }

    func readableStore() -> TraceStore? {
        openStore()
    }

    func shutDown() async {
        await producer?.shutDown()
    }

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
    var traceRetentionWindow: TraceRetentionWindow {
        guard traceRecordingEnabled else { return .clearAll }
        return TraceRetentionWindow(
            days: traceRetentionDays == 0 ? nil : traceRetentionDays,
            maximumTraces: traceMaximumTraces == 0 ? nil : traceMaximumTraces
        )
    }
}
