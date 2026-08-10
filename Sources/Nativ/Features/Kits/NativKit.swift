import Foundation

enum NativKitOrigin: String, Codable, Equatable, Sendable {
    case builtIn
    case user
}

enum NativKitMCPServerReference: Codable, Equatable, Hashable, Sendable {
    case catalog(String)
    case configured(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case catalogID
        case serverID
    }

    private enum Kind: String, Codable {
        case catalog
        case configured
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .catalog:
            self = .catalog(try container.decode(String.self, forKey: .catalogID))
        case .configured:
            self = .configured(try container.decode(UUID.self, forKey: .serverID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .catalog(let id):
            try container.encode(Kind.catalog, forKey: .kind)
            try container.encode(id, forKey: .catalogID)
        case .configured(let id):
            try container.encode(Kind.configured, forKey: .kind)
            try container.encode(id, forKey: .serverID)
        }
    }
}

enum NativKitMCPToolSelection: Codable, Equatable, Hashable, Sendable {
    case all
    case named([String])

    private enum CodingKeys: String, CodingKey {
        case mode
        case names
    }

    private enum Mode: String, Codable {
        case all
        case named
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .all:
            self = .all
        case .named:
            self = .named(try container.decodeIfPresent([String].self, forKey: .names) ?? [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(Mode.all, forKey: .mode)
        case .named(let names):
            try container.encode(Mode.named, forKey: .mode)
            try container.encode(names, forKey: .names)
        }
    }

    func normalized() -> Self {
        switch self {
        case .all:
            return .all
        case .named(let names):
            return .named(Array(Set(names.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }).filter { !$0.isEmpty }).sorted())
        }
    }
}

struct NativKitMCPSelection: Codable, Equatable, Hashable, Sendable, Identifiable {
    var server: NativKitMCPServerReference
    var tools: NativKitMCPToolSelection

    var id: NativKitMCPServerReference { server }
}

enum NativKitSkillReference: Codable, Equatable, Hashable, Sendable {
    case builtIn(String)
    case configured(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case builtInID
        case skillID
    }

    private enum Kind: String, Codable {
        case builtIn
        case configured
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .builtIn:
            self = .builtIn(try container.decode(String.self, forKey: .builtInID))
        case .configured:
            self = .configured(try container.decode(UUID.self, forKey: .skillID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let id):
            try container.encode(Kind.builtIn, forKey: .kind)
            try container.encode(id, forKey: .builtInID)
        case .configured(let id):
            try container.encode(Kind.configured, forKey: .kind)
            try container.encode(id, forKey: .skillID)
        }
    }
}

enum NativKitCapabilityReference: Equatable, Hashable, Sendable {
    case mcp(NativKitMCPServerReference)
    case mcpTool(server: NativKitMCPServerReference, name: String)
    case nativeTool(String)
    case customTool(UUID)
    case skill(NativKitSkillReference)

    var id: String {
        switch self {
        case .mcp(.catalog(let id)):
            "mcp-catalog:\(id)"
        case .mcp(.configured(let id)):
            "mcp:\(id.uuidString)"
        case .mcpTool(let server, let name):
            "\(NativKitCapabilityReference.mcp(server).id):tool:\(name)"
        case .nativeTool(let name):
            "native:\(name)"
        case .customTool(let id):
            "custom:\(id.uuidString)"
        case .skill(.builtIn(let id)):
            "skill-builtin:\(id)"
        case .skill(.configured(let id)):
            "skill:\(id.uuidString)"
        }
    }
}

struct NativKitContents: Codable, Equatable, Sendable {
    var mcpSelections: [NativKitMCPSelection] = []
    var nativeToolNames: [String] = []
    var customToolIDs: [UUID] = []
    var skillReferences: [NativKitSkillReference] = []

    var isEmpty: Bool {
        mcpSelections.isEmpty
            && nativeToolNames.isEmpty
            && customToolIDs.isEmpty
            && skillReferences.isEmpty
    }

    var inventory: String {
        var parts: [String] = []
        if !mcpSelections.isEmpty {
            parts.append(Self.count(mcpSelections.count, singular: "MCP"))
        }
        let toolCount = nativeToolNames.count + customToolIDs.count
            + mcpSelections.reduce(0) { partial, selection in
                guard case .named(let names) = selection.tools else { return partial }
                return partial + names.count
            }
        if toolCount > 0 {
            parts.append(Self.count(toolCount, singular: "tool"))
        }
        if !skillReferences.isEmpty {
            parts.append(Self.count(skillReferences.count, singular: "skill"))
        }
        return parts.joined(separator: " · ")
    }

    func normalized() -> Self {
        var result = self
        var seenServers = Set<NativKitMCPServerReference>()
        result.mcpSelections = mcpSelections.compactMap { selection in
            guard seenServers.insert(selection.server).inserted else { return nil }
            let tools = selection.tools.normalized()
            if case .named(let names) = tools, names.isEmpty { return nil }
            return NativKitMCPSelection(server: selection.server, tools: tools)
        }
        result.nativeToolNames = Array(Set(nativeToolNames)).sorted()
        result.customToolIDs = customToolIDs.uniqued()
        result.skillReferences = skillReferences.uniqued()
        return result
    }

    private static func count(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

struct UserNativKit: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var summary: String = ""
    var isEnabled = true
    var contents = NativKitContents()

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !contents.normalized().isEmpty
    }

    func normalized() -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        result.contents = contents.normalized()
        return result
    }

    func resolved() -> CustomNativKit {
        let value = normalized()
        return CustomNativKit(
            id: value.id.uuidString,
            name: value.name,
            summary: value.summary,
            isEnabled: value.isEnabled,
            origin: .user,
            contents: value.contents
        )
    }
}

struct CustomNativKit: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var summary: String
    var isEnabled: Bool
    let origin: NativKitOrigin
    var contents: NativKitContents

    var isBuiltIn: Bool { origin == .builtIn }
    var inventory: String { contents.inventory }

    func normalized() -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        result.contents = contents.normalized()
        return result
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
