import Foundation

enum RoutineTriggerKind: String, Codable, Equatable, Sendable {
    case schedule
    case api
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
    var kitID: String?
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
        kitID: String? = nil,
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
        self.kitID = kitID
        self.isEnabled = isEnabled
        self.notifyOnFinish = notifyOnFinish
        self.createdAt = createdAt
        self.sourceSessionID = sourceSessionID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, instructions, modelID, triggerKind, schedule, kitID
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
        kitID = try container.decodeIfPresent(String.self, forKey: .kitID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        notifyOnFinish = try container.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sourceSessionID = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
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
    case cancelled
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
