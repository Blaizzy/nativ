import Foundation
import NativServerKit

struct RuntimeSettingField: Identifiable, Equatable {
    enum Control: Equatable {
        case toggle
        case number(isInteger: Bool)
        case choice([String])
        case combo([String], isInteger: Bool)
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
        if let closed = Self.closedChoices[spec.name] {
            return .choice(closed)
        }
        if let presets = Self.presets[spec.name] {
            return .combo(presets, isInteger: !spec.type.hasPrefix("float"))
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

    /// Human label with the redundant group prefix removed ("KV Bits" under a
    /// "KV Cache" header becomes "Bits"). Falls back to a derived title for
    /// knobs the server adds later.
    var shortTitle: String {
        if let override = Self.nameOverrides[spec.name] {
            return override
        }
        var stem = spec.name
        if let prefix = group.namePrefix, stem.hasPrefix(prefix) {
            stem.removeFirst(prefix.count)
        }
        return Self.titleCase(stem)
    }

    /// Unit rendered as a trailing suffix on the control rather than baked into
    /// the label (fixes "Gb" → "GB" and keeps the label clean).
    var unitSuffix: String? {
        Self.units[spec.name]
    }

    /// What the value resolves to when it is left unset, shown muted in place
    /// of a bare "Default". Only surfaced while the value is null, so the null
    /// meaning wins over the concrete default (e.g. clearing the queue timeout
    /// disables it rather than reverting to the default seconds).
    var resolvedHint: String {
        if let meaning = Self.nullMeaning[spec.name] {
            return meaning
        }
        if !spec.defaultValue.isNull {
            return spec.defaultValue.displayText
        }
        return "not set"
    }

    private static func titleCase(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { segment -> String in
                let word = String(segment)
                switch word {
                case "kv", "apc", "id", "gb":
                    return word.uppercased()
                default:
                    return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private static let nameOverrides: [String: String] = [
        "kv_bits": "Bits",
        "kv_quant_scheme": "Quant Scheme",
        "kv_group_size": "Group Size",
        "kv_key_bits": "Key Bits",
        "kv_value_bits": "Value Bits",
        "kv_key_scheme": "Key Scheme",
        "kv_value_scheme": "Value Scheme",
        "quantized_kv_start": "Quantized Start",
        "apc_enabled": "Enabled",
        "apc_disk_path": "Disk Path",
        "apc_block_size": "Block Size",
        "apc_num_blocks": "Block Pool",
        "apc_disk_max_gb": "Disk Cap",
        "max_kv_size": "Max KV Size",
        "token_queue_timeout": "Queue Timeout",
        "spec_draft_model": "Draft Model",
        "spec_draft_kind": "Draft Kind",
        "vision_cache_size": "Cache Size",
    ]

    private static let closedChoices: [String: [String]] = [
        "spec_draft_kind": ["mtp", "dflash", "eagle3"],
    ]

    private static let presets: [String: [String]] = [
        "kv_bits": ["2", "3", "4", "5", "6", "8"],
        "max_kv_size": ["2048", "4096", "8192", "16384", "32768", "65536"],
    ]

    private static let units: [String: String] = [
        "apc_disk_max_gb": "GB",
        "token_queue_timeout": "sec",
        "apc_block_size": "tok",
        "apc_num_blocks": "blocks",
        "max_kv_size": "tok",
        "vision_cache_size": "images",
    ]

    // One grammar: a muted lowercase "effective state" phrase for the null
    // case. The server returns raw null (not the resolved number), so these
    // describe behavior rather than echo a value you could type back.
    private static let nullMeaning: [String: String] = [
        "kv_bits": "unquantized",
        "kv_group_size": "auto",
        "kv_key_bits": "inherits Bits",
        "kv_value_bits": "inherits Bits",
        "kv_key_scheme": "inherits scheme",
        "kv_value_scheme": "inherits scheme",
        "quantized_kv_start": "all layers",
        "apc_disk_path": "memory only",
        "apc_disk_max_gb": "uncapped",
        "max_kv_size": "full context",
        "token_queue_timeout": "no timeout",
        "spec_draft_model": "off",
        "spec_draft_kind": "auto",
    ]
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

    var namePrefix: String? {
        switch self {
        case .kvCache: return "kv_"
        case .prefixCache: return "apc_"
        case .speculativeDecoding: return "spec_"
        case .vision: return "vision_"
        case .requests: return nil
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
    @Published private(set) var appliedNotice: String?
    @Published private(set) var isApplying = false
    @Published private(set) var applyError: String?

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

    /// Whether a field currently has any effect. Mirrors the server's own
    /// dependencies so we never present a control that silently does nothing:
    /// the whole KV group is inert until `kv_bits` is set (ar.py builds a plain
    /// cache otherwise), and the APC group is inert until `apc_enabled` is on
    /// (RuntimeConfig drops those knobs from the cache key).
    func isActive(_ field: RuntimeSettingField) -> Bool {
        switch field.group {
        case .kvCache:
            if field.id == "kv_bits" { return true }
            guard let bits = value(named: "kv_bits") else { return true }
            return !bits.isNull
        case .prefixCache:
            if field.id == "apc_enabled" { return true }
            return value(named: "apc_enabled")?.boolValue ?? false
        default:
            return true
        }
    }

    /// A short muted note for a group whose dependent fields are inert, or nil.
    /// Phrased in parallel across groups.
    func inactiveHint(for group: RuntimeSettingGroup) -> String? {
        switch group {
        case .kvCache:
            let bits = value(named: "kv_bits")
            return (bits?.isNull ?? true) ? "set Bits to enable" : nil
        case .prefixCache:
            let enabled = value(named: "apc_enabled")?.boolValue ?? false
            return enabled ? nil : "turn on to enable"
        default:
            return nil
        }
    }

    private func value(named name: String) -> RuntimeSettingValue? {
        fields.first { $0.id == name }?.value
    }

    func setValue(_ value: RuntimeSettingValue, for name: String) {
        guard let index = fields.firstIndex(where: { $0.id == name }) else { return }
        fields[index].value = value
        appliedNotice = nil
    }

    func resetToDefault(_ name: String) {
        guard let index = fields.firstIndex(where: { $0.id == name }) else { return }
        fields[index].value = fields[index].spec.defaultValue
        appliedNotice = nil
    }

    func dismissAppliedNotice() {
        appliedNotice = nil
    }

    func discardChanges() {
        for index in fields.indices {
            fields[index].value = fields[index].serverValue
        }
        rejections = []
        applyError = nil
        appliedNotice = nil
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
            appliedNotice = nil
            state = .loaded
        } catch let error as NativRuntimeSettingsError where error.isUnsupported {
            fields = []
            state = .unsupported
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func apply() async {
        let changes = dirtyFields
        guard !changes.isEmpty else { return }
        var payload: [String: RuntimeSettingValue] = [:]
        for field in changes {
            payload[field.spec.name] = field.value
        }
        await send { endpoint in
            let client = NativRuntimeSettingsClient(baseURL: endpoint.url, apiKey: endpoint.key)
            let update = try await client.update(payload)
            self.adopt(update)
            self.onAdopt?(update.applied)
            self.appliedNotice = Self.appliedText(
                count: update.applied.count,
                kinds: update.reloadKinds
            )
        }
    }

    func restoreServerDefaults() async {
        await send { endpoint in
            let client = NativRuntimeSettingsClient(baseURL: endpoint.url, apiKey: endpoint.key)
            let update = try await client.update([:], resettingUnlistedToDefaults: true)
            self.adopt(update)
            self.onAdopt?(update.current)
            self.appliedNotice = "Restored server defaults"
        }
    }

    private func send(
        _ body: @MainActor ((url: URL, key: String?)) async throws -> Void
    ) async {
        guard let endpoint, !isApplying else { return }
        isApplying = true
        rejections = []
        applyError = nil
        defer { isApplying = false }
        do {
            try await body(endpoint)
        } catch {
            applyError = error.localizedDescription
        }
    }

    private func adopt(_ update: RuntimeSettingsUpdate) {
        rejections = update.rejected
        fingerprint = update.fingerprint
        merge(current: update.current)
    }

    private static func appliedText(count: Int, kinds: [String]) -> String {
        let noun = count == 1 ? "setting" : "settings"
        guard !kinds.isEmpty else {
            return "Applied \(count) \(noun)"
        }
        let readable = kinds.map { $0.replacingOccurrences(of: "_", with: " ") }
        return "Applied \(count) \(noun) — reloading \(readable.joined(separator: ", "))"
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
