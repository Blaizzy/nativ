import Foundation
import NativServerKit

struct RuntimeSettingField: Identifiable, Equatable {
    enum Control: Equatable {
        case toggle
        case number(isInteger: Bool)
        case choice([String])
        case text
    }

    let spec: RuntimeSettingSpec
    var value: RuntimeSettingValue
    var serverValue: RuntimeSettingValue

    var id: String { spec.name }

    var isDirty: Bool {
        value != serverValue
    }

    var isDefault: Bool {
        value == spec.defaultValue
    }

    var control: Control {
        if let allowed = spec.allowed, !allowed.isEmpty {
            return .choice(allowed)
        }
        switch spec.type {
        case "bool":
            return .toggle
        case "int", "int_or_none":
            return .number(isInteger: true)
        case "float", "float_or_none":
            return .number(isInteger: false)
        default:
            return .text
        }
    }

    var title: String {
        spec.name
            .split(separator: "_")
            .map { segment -> String in
                let word = String(segment)
                switch word {
                case "kv", "apc", "id":
                    return word.uppercased()
                default:
                    return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    var group: RuntimeSettingGroup {
        if spec.name.hasPrefix("apc_") {
            return .prefixCache
        }
        if spec.name.hasPrefix("kv_") || spec.name.hasPrefix("quantized_kv") {
            return .kvCache
        }
        if spec.name.hasPrefix("spec_") {
            return .speculativeDecoding
        }
        if spec.name.hasPrefix("vision_") {
            return .vision
        }
        return .requests
    }
}

enum RuntimeSettingGroup: String, CaseIterable, Identifiable {
    case requests
    case kvCache
    case prefixCache
    case speculativeDecoding
    case vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests: return "Requests"
        case .kvCache: return "KV Cache"
        case .prefixCache: return "Prefix Cache"
        case .speculativeDecoding: return "Speculative Decoding"
        case .vision: return "Vision"
        }
    }

    var symbol: String {
        switch self {
        case .requests: return "timer"
        case .kvCache: return "memorychip"
        case .prefixCache: return "square.stack.3d.up"
        case .speculativeDecoding: return "hare"
        case .vision: return "eye"
        }
    }
}

@MainActor
final class RuntimeSettingsStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unsupported
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var fields: [RuntimeSettingField] = []
    @Published private(set) var fingerprint = ""
    @Published private(set) var rejections: [RuntimeSettingRejection] = []
    @Published private(set) var lastReloadKinds: [String] = []
    @Published private(set) var isApplying = false

    private var endpoint: (url: URL, key: String?)?
    private var onAdopt: (([String: RuntimeSettingValue]) -> Void)?

    var isDirty: Bool {
        fields.contains(where: \.isDirty)
    }

    var dirtyFields: [RuntimeSettingField] {
        fields.filter(\.isDirty)
    }

    var reloadWarningKinds: [String] {
        Array(Set(dirtyFields.flatMap { $0.spec.reloadKinds })).sorted()
    }

    var groups: [RuntimeSettingGroup] {
        RuntimeSettingGroup.allCases.filter { group in
            fields.contains { $0.group == group }
        }
    }

    func fields(in group: RuntimeSettingGroup) -> [RuntimeSettingField] {
        fields.filter { $0.group == group }
    }

    func binding(for name: String) -> RuntimeSettingField? {
        fields.first { $0.id == name }
    }

    func setValue(_ value: RuntimeSettingValue, for name: String) {
        guard let index = fields.firstIndex(where: { $0.id == name }) else { return }
        fields[index].value = value
    }

    func revert(_ name: String) {
        guard let index = fields.firstIndex(where: { $0.id == name }) else { return }
        fields[index].value = fields[index].serverValue
    }

    func resetToDefault(_ name: String) {
        guard let index = fields.firstIndex(where: { $0.id == name }) else { return }
        fields[index].value = fields[index].spec.defaultValue
    }

    func discardChanges() {
        for index in fields.indices {
            fields[index].value = fields[index].serverValue
        }
        rejections = []
    }

    func onServerAccepted(_ handler: @escaping ([String: RuntimeSettingValue]) -> Void) {
        onAdopt = handler
    }

    func connect(to url: URL, apiKey: String?) {
        let normalizedKey = apiKey?.isEmpty == true ? nil : apiKey
        if let endpoint, endpoint.url == url, endpoint.key == normalizedKey, case .loaded = state {
            return
        }
        endpoint = (url, normalizedKey)
        Task { await load() }
    }

    func load() async {
        guard let endpoint else { return }
        let client = NativRuntimeSettingsClient(baseURL: endpoint.url, apiKey: endpoint.key)
        if case .loaded = state {} else {
            state = .loading
        }
        do {
            let snapshot = try await client.fetch()
            apply(snapshot: snapshot)
            state = .loaded
        } catch let error as NativRuntimeSettingsError where error.isUnsupported {
            fields = []
            state = .unsupported
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func apply() async {
        guard let endpoint, !isApplying else { return }
        let changes = dirtyFields
        guard !changes.isEmpty else { return }
        isApplying = true
        rejections = []
        defer { isApplying = false }

        var payload: [String: RuntimeSettingValue] = [:]
        for field in changes {
            payload[field.spec.name] = field.value
        }
        let client = NativRuntimeSettingsClient(baseURL: endpoint.url, apiKey: endpoint.key)
        do {
            let update = try await client.update(payload)
            rejections = update.rejected
            lastReloadKinds = update.reloadKinds
            fingerprint = update.fingerprint
            merge(current: update.current)
            onAdopt?(update.applied)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func restoreServerDefaults() async {
        guard let endpoint, !isApplying else { return }
        isApplying = true
        rejections = []
        defer { isApplying = false }
        let client = NativRuntimeSettingsClient(baseURL: endpoint.url, apiKey: endpoint.key)
        do {
            let update = try await client.update([:], resettingUnlistedToDefaults: true)
            rejections = update.rejected
            lastReloadKinds = update.reloadKinds
            fingerprint = update.fingerprint
            merge(current: update.current)
            onAdopt?(update.current)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(snapshot: RuntimeSettingsSnapshot) {
        fingerprint = snapshot.fingerprint
        let edits = Dictionary(
            uniqueKeysWithValues: fields.filter(\.isDirty).map { ($0.id, $0.value) }
        )
        fields = snapshot.schema.map { spec in
            let serverValue = snapshot.current[spec.name] ?? spec.defaultValue
            return RuntimeSettingField(
                spec: spec,
                value: edits[spec.name] ?? serverValue,
                serverValue: serverValue
            )
        }
    }

    private func merge(current: [String: RuntimeSettingValue]) {
        guard !current.isEmpty else { return }
        for index in fields.indices {
            guard let serverValue = current[fields[index].spec.name] else { continue }
            fields[index].serverValue = serverValue
            fields[index].value = serverValue
        }
    }
}
