import Foundation

public enum NativWorkspaceValueType: String, Codable, Hashable, Sendable {
    case text, number, boolean

    public func accepts(_ value: NativWorkflowValue) -> Bool {
        switch (self, value) {
        case (.text, .text(let text)): text.utf8.count <= 65_536
        case (.number, .number(let number)): number.isFinite
        case (.boolean, .boolean): true
        default: false
        }
    }
}

public struct NativWorkspaceField: Codable, Hashable, Sendable {
    public let type: NativWorkspaceValueType
    public let defaultValue: NativWorkflowValue

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["type", "defaultValue"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(NativWorkspaceValueType.self, forKey: .type)
        defaultValue = try container.decode(NativWorkflowValue.self, forKey: .defaultValue)
    }
}

public struct NativExtensionDashboard: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let title: String
    public let storage: [String: NativWorkspaceField]
    public let tabs: [NativDashboardTab]

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["schemaVersion", "title", "storage", "tabs"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        title = try container.decode(String.self, forKey: .title)
        storage = try container.decode([String: NativWorkspaceField].self, forKey: .storage)
        tabs = try container.decode([NativDashboardTab].self, forKey: .tabs)
    }
}

public struct NativDashboardTab: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let sections: [NativDashboardSection]

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["id", "title", "sections"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sections = try container.decode([NativDashboardSection].self, forKey: .sections)
    }
}

public struct NativDashboardSection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let components: [NativDashboardComponent]

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["id", "title", "components"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        components = try container.decode([NativDashboardComponent].self, forKey: .components)
    }
}

public struct NativDashboardComponent: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, textField, toggle, picker, button }
    public let id: String
    public let type: Kind
    public let title: String
    public let text: String?
    public let storageKey: String?
    public let commandID: String?
    public let options: [String]?

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["id", "type", "title", "text", "storageKey", "commandID", "options"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(Kind.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey)
        commandID = try container.decodeIfPresent(String.self, forKey: .commandID)
        options = try container.decodeIfPresent([String].self, forKey: .options)
    }
}

public enum NativDashboardError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): "Dashboard.json: \(reason)" }
    }
}

public enum NativExtensionDashboardValidator {
    public static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64 && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public static func validate(_ dashboard: NativExtensionDashboard, manifest: NativExtensionManifest) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NativDashboardError.invalid(message) }
        }
        func label(_ text: String) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 256
        }
        try require(dashboard.schemaVersion == 1, "Unsupported schema version.")
        try require(label(dashboard.title), "Provide a title of at most 256 bytes.")
        try require((1...8).contains(dashboard.tabs.count), "Provide between 1 and 8 tabs.")
        try require(dashboard.storage.count <= 64, "At most 64 storage fields are supported.")
        try require(dashboard.storage.isEmpty || manifest.permissions.contains(.namespacedStorage), "Declare storage.namespaced to use persistent state.")
        for (key, field) in dashboard.storage {
            try require(validKey(key) && field.type.accepts(field.defaultValue), "Invalid storage declaration: \(key).")
        }
        let defaults = try JSONEncoder().encode(dashboard.storage.mapValues(\.defaultValue))
        try require(defaults.count <= NativExtensionWorkspaceStorage.maximumBytes, "Storage defaults exceed the workspace size limit.")
        let commands = Set(manifest.contributions.commands.map(\.id))
        var ids = Set<String>()
        var componentCount = 0
        func identity(_ id: String, _ title: String) throws {
            try require(validKey(id) && ids.insert(id).inserted && label(title), "IDs must be valid and unique; titles must be nonempty and bounded.")
        }
        for tab in dashboard.tabs {
            try identity(tab.id, tab.title)
            try require((1...16).contains(tab.sections.count), "Provide between 1 and 16 sections per tab.")
            for section in tab.sections {
                try identity(section.id, section.title)
                try require(!section.components.isEmpty, "Sections must contain components.")
                for component in section.components {
                    componentCount += 1
                    try require(componentCount <= 128, "At most 128 components are supported.")
                    try identity(component.id, component.title)
                    let field = component.storageKey.flatMap { dashboard.storage[$0] }
                    if component.storageKey != nil {
                        try require(field != nil, "Undeclared storage key for \(component.id).")
                    }
                    try require(component.type == .button || component.commandID == nil, "Only buttons accept commandID.")
                    try require(component.type == .picker || component.options == nil, "Only pickers accept options.")
                    try require(component.type == .text || component.text == nil, "Only text components accept literal text.")
                    switch component.type {
                    case .text:
                        try require((component.text != nil) != (component.storageKey != nil), "Text requires either literal text or a storage key.")
                        try require((component.text?.utf8.count ?? 0) <= 65_536, "Text exceeds its size limit.")
                    case .textField:
                        try require(field?.type == .text || field?.type == .number, "Text fields bind to text or number storage.")
                    case .toggle:
                        try require(field?.type == .boolean, "Toggles bind to boolean storage.")
                    case .picker:
                        let options = component.options ?? []
                        try require(field?.type == .text && (1...32).contains(options.count)
                            && Set(options).count == options.count && options.allSatisfy(label), "Pickers require text storage and 1–32 unique options.")
                        try require(options.contains(field?.defaultValue.text ?? ""), "Picker defaults must match an option.")
                    case .button:
                        try require(component.storageKey == nil && commands.contains(component.commandID ?? ""), "Buttons must reference a contributed command.")
                    }
                }
            }
        }
    }
}
