import Foundation
import NativServerKit
import Observation

/// Coalesces edits and sends them in order. Never cancels an in-flight PATCH
/// for another edit: the server may already have applied it.
@MainActor
@Observable
final class NativRuntimeSettingsController {
    typealias Values = [String: MLXJSONValue]
    typealias Update = @Sendable (Values) async throws -> NativRuntimeSettingsResponse

    private(set) var errorMessage: String?
    private(set) var isApplying = false
    private(set) var hasPendingChanges = false
    @ObservationIgnored private var applied: Values = [:]
    @ObservationIgnored private var desired: Values = [:]
    @ObservationIgnored private var update: Update?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var ready = false
    @ObservationIgnored private let debounce: Duration

    init(debounce: Duration = .milliseconds(250)) {
        self.debounce = debounce
    }

    func start(applied: Values, update: @escaping Update) {
        stop()
        self.applied = applied
        desired = applied
        self.update = update
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        update = nil
        ready = false
        isApplying = false
        hasPendingChanges = false
        errorMessage = nil
    }

    func setDesired(_ values: Values) {
        guard update != nil, values != desired else { return }
        desired = values
        errorMessage = nil
        schedule()
    }

    func serverBecameReady() {
        guard !ready else { return }
        ready = true
        schedule()
    }

    func retry() {
        errorMessage = nil
        schedule()
    }

    private var changes: Values { desired.filter { applied[$0.key] != $0.value } }

    private func schedule() {
        hasPendingChanges = !changes.isEmpty
        guard ready, hasPendingChanges, task == nil, let update else { return }
        let generation = generation
        isApplying = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.task = nil
                    self.isApplying = false
                    self.hasPendingChanges = !self.changes.isEmpty
                }
            }
            while self.generation == generation {
                do { try await Task.sleep(for: self.debounce) } catch { return }
                let sent = self.changes
                guard !sent.isEmpty else { return }
                do {
                    let response = try await update(sent)
                    guard self.generation == generation else { return }
                    self.applied.merge(response.current) { _, current in current }
                    let unapplied = sent.filter { self.applied[$0.key] != $0.value }
                    if !response.rejected.isEmpty || !unapplied.isEmpty {
                        let details = response.rejected.map { "\($0.name): \($0.reason)" }
                        self.errorMessage = details.isEmpty
                            ? "The server did not apply: \(unapplied.keys.sorted().joined(separator: ", "))."
                            : details.joined(separator: "; ")
                        return
                    }
                    self.errorMessage = nil
                } catch {
                    guard self.generation == generation else { return }
                    // A lost response does not prove the PATCH failed. Force a
                    // corrective write even if the user reverts to the old value.
                    for key in sent.keys { self.applied.removeValue(forKey: key) }
                    self.errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }
}
