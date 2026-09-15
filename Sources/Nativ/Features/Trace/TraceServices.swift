import Foundation
import os

@MainActor
final class TraceServices {
    static let shared = TraceServices()

    private let logger = Logger(subsystem: "dev.local.Nativ", category: "trace")
    private let makeStore: () throws -> TraceStore
    private var store: TraceStore?
    private(set) var producer: ChatTraceProducer?

    init(makeStore: @escaping () throws -> TraceStore = { try TraceStore() }) {
        self.makeStore = makeStore
    }

    @discardableResult
    func start() -> ChatTraceProducer? {
        if let producer { return producer }

        guard let store = openStore() else { return nil }
        Task { try? await store.prune(retaining: .default) }
        let recorder = TraceRecorder(store: store)
        let producer = ChatTraceProducer(recorder: recorder)
        self.producer = producer
        return producer
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
        store = nil
    }
}
