import Foundation
import NativExtensionSDK
import Observation

@Observable
@MainActor
final class NativWorkspaceState {
    private(set) var values: [String: NativWorkflowValue] = [:]
    private(set) var loadError: String?
    var errorMessage: String?
    private let storage: NativExtensionWorkspaceStorage
    private var pendingSave: Task<Void, Never>?
    private var isDirty = false
    private let fields: [String: NativWorkspaceField]

    init(directory: URL, fields: [String: NativWorkspaceField]) {
        self.fields = fields
        storage = NativExtensionWorkspaceStorage(directory: directory, fields: fields)
        do {
            values = try storage.load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func read(_ key: String) throws -> NativWorkflowValue {
        guard loadError == nil, let value = values[key] else {
            throw NativDashboardError.invalid(loadError ?? "Unknown storage key: \(key).")
        }
        return value
    }

    func stage(_ key: String, value: NativWorkflowValue) throws {
        guard loadError == nil, let field = fields[key], field.type.accepts(value) else {
            throw NativDashboardError.invalid(loadError ?? "Invalid value for storage key: \(key).")
        }
        guard values[key] != value else { return }
        values[key] = value
        isDirty = true
        errorMessage = nil
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try self?.flush()
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func flush() throws {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty else { return }
        try storage.save(values)
        isDirty = false
        errorMessage = nil
    }

    func write(_ key: String, value: NativWorkflowValue) throws {
        try stage(key, value: value)
        try flush()
    }
}
