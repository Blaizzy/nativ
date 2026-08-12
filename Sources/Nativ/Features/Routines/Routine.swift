import Foundation

enum RoutineTriggerKind: String, Codable, Equatable, Sendable {
    case schedule
    case api
}

struct ScheduledTool: Codable, Hashable, Sendable {
    enum Provider: Hashable, Sendable {
        case builtIn
        case custom(UUID)
        case mcp(UUID)
    }

    let provider: Provider
    let name: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.provider, rhs.provider) {
        case (.custom(let lhsID), .custom(let rhsID)):
            lhsID == rhsID
        default:
            lhs.provider == rhs.provider && lhs.name == rhs.name
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        if case .custom = provider {
            return
        }
        hasher.combine(name)
    }

    fileprivate var stableID: String {
        switch provider {
        case .builtIn:
            "built-in:\(name)"
        case .custom(let id):
            "custom:\(id.uuidString)"
        case .mcp(let id):
            "mcp:\(id.uuidString):\(name)"
        }
    }
}

extension ScheduledTool.Provider: Codable {
    private enum Kind: String, Codable {
        case builtIn
        case custom
        case mcp
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .builtIn:
            self = .builtIn
        case .custom:
            self = .custom(try container.decode(UUID.self, forKey: .id))
        case .mcp:
            self = .mcp(try container.decode(UUID.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn:
            try container.encode(Kind.builtIn, forKey: .kind)
        case .custom(let id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .mcp(let id):
            try container.encode(Kind.mcp, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

enum ScheduledCapability: Hashable, Sendable, Identifiable {
    case kit(String)
    case mcpServer(UUID)
    case tool(ScheduledTool)
    case skill(UUID)

    var id: String {
        switch self {
        case .kit(let id):
            "kit:\(id)"
        case .mcpServer(let id):
            "mcp:\(id.uuidString)"
        case .tool(let tool):
            "tool:\(tool.stableID)"
        case .skill(let id):
            "skill:\(id.uuidString)"
        }
    }
}

extension ScheduledCapability: Codable {
    private enum Kind: String, Codable {
        case kit
        case mcpServer
        case tool
        case skill
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case kitID
        case serverID
        case tool
        case skillID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .kit:
            self = .kit(try container.decode(String.self, forKey: .kitID))
        case .mcpServer:
            self = .mcpServer(try container.decode(UUID.self, forKey: .serverID))
        case .tool:
            self = .tool(try container.decode(ScheduledTool.self, forKey: .tool))
        case .skill:
            self = .skill(try container.decode(UUID.self, forKey: .skillID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .kit(let id):
            try container.encode(Kind.kit, forKey: .kind)
            try container.encode(id, forKey: .kitID)
        case .mcpServer(let id):
            try container.encode(Kind.mcpServer, forKey: .kind)
            try container.encode(id, forKey: .serverID)
        case .tool(let tool):
            try container.encode(Kind.tool, forKey: .kind)
            try container.encode(tool, forKey: .tool)
        case .skill(let id):
            try container.encode(Kind.skill, forKey: .kind)
            try container.encode(id, forKey: .skillID)
        }
    }
}

struct RoutineSchedule: Codable, Equatable, Sendable {
    var weekdays: Set<Int>
    var hour: Int
    var minute: Int

    init(weekdays: Set<Int> = [], hour: Int = 9, minute: Int = 0) {
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    var runsEveryDay: Bool { weekdays.isEmpty }

    func nextFireDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0

        if runsEveryDay {
            return calendar.nextDate(
                after: date,
                matching: components,
                matchingPolicy: .nextTime
            )
        }

        return weekdays.compactMap { weekday -> Date? in
            var dayComponents = components
            dayComponents.weekday = weekday
            return calendar.nextDate(
                after: date,
                matching: dayComponents,
                matchingPolicy: .nextTime
            )
        }.min()
    }
}

struct Routine: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var instructions: String
    var modelID: String
    var triggerKind: RoutineTriggerKind
    var schedule: RoutineSchedule
    var capabilities: [ScheduledCapability]
    var isEnabled: Bool
    var notifyOnFinish: Bool
    var createdAt: Date
    var sourceSessionID: UUID?

    init(
        id: String = UUID().uuidString,
        name: String = "",
        instructions: String = "",
        modelID: String = "",
        triggerKind: RoutineTriggerKind = .schedule,
        schedule: RoutineSchedule = RoutineSchedule(),
        capabilities: [ScheduledCapability] = [],
        isEnabled: Bool = true,
        notifyOnFinish: Bool = true,
        createdAt: Date = Date(),
        sourceSessionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.modelID = modelID
        self.triggerKind = triggerKind
        self.schedule = schedule
        self.capabilities = capabilities
        self.isEnabled = isEnabled
        self.notifyOnFinish = notifyOnFinish
        self.createdAt = createdAt
        self.sourceSessionID = sourceSessionID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, instructions, modelID, triggerKind, schedule, capabilities, kitID
        case isEnabled, notifyOnFinish, createdAt, sourceSessionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        triggerKind = try container.decodeIfPresent(RoutineTriggerKind.self, forKey: .triggerKind) ?? .schedule
        schedule = try container.decodeIfPresent(RoutineSchedule.self, forKey: .schedule) ?? RoutineSchedule()
        if let storedCapabilities = try container.decodeIfPresent(
            [ScheduledCapability].self,
            forKey: .capabilities
        ) {
            capabilities = storedCapabilities
        } else if let legacyKitID = try container.decodeIfPresent(String.self, forKey: .kitID) {
            capabilities = [.kit(legacyKitID)]
        } else {
            capabilities = []
        }
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        notifyOnFinish = try container.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sourceSessionID = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(triggerKind, forKey: .triggerKind)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(notifyOnFinish, forKey: .notifyOnFinish)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(sourceSessionID, forKey: .sourceSessionID)
    }

    var runsOnSchedule: Bool { triggerKind == .schedule }

    func nextFireDate(after date: Date = Date()) -> Date? {
        guard isEnabled, runsOnSchedule else { return nil }
        return schedule.nextFireDate(after: date)
    }
}

enum RoutineRunSource: String, Codable, Equatable, Sendable {
    case scheduled
    case manual
    case api
}

enum RoutineRunStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
}

struct RoutineRun: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var routineID: String
    var startedAt: Date
    var finishedAt: Date?
    var source: RoutineRunSource
    var sessionID: UUID?
    var status: RoutineRunStatus
    var resultSummary: String

    init(
        id: String = UUID().uuidString,
        routineID: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        source: RoutineRunSource,
        sessionID: UUID? = nil,
        status: RoutineRunStatus = .running,
        resultSummary: String = ""
    ) {
        self.id = id
        self.routineID = routineID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.source = source
        self.sessionID = sessionID
        self.status = status
        self.resultSummary = resultSummary
    }
}
