import Foundation

enum ChatSpawnedAgentStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case error
    case stopped
}

enum ChatSpawnedAgentStopReason: String, Codable, Equatable, Sendable {
    case turnLimit = "turn_limit"
    case tokenLimit = "token_limit"
    case timeout
    case cancelled
}

struct ChatSpawnedAgentRecord: Identifiable, Equatable, Sendable {
    let id: String
    let task: String
    var modelID: String?
    var status: ChatSpawnedAgentStatus
    var stopReason: ChatSpawnedAgentStopReason?
    var result: String?
    var error: String?
    let startedAt: Date
    var finishedAt: Date?
}

/// In-memory only. Owned by ChatViewModel so it survives session switches
/// but not app relaunch.
@MainActor
final class ChatAgentRegistry {
    private static let maximumTrackedTerminalAgents = 50

    private var records: [String: ChatSpawnedAgentRecord] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pendingSteerMessages: [String: [String]] = [:]
    private var sequence = 0

    func register(task: String, modelID: String?) -> String {
        sequence += 1
        let id = "agent_\(sequence)"
        records[id] = ChatSpawnedAgentRecord(
            id: id,
            task: task,
            modelID: modelID,
            status: .queued,
            stopReason: nil,
            result: nil,
            error: nil,
            startedAt: Date(),
            finishedAt: nil
        )
        order.append(id)
        return id
    }

    func setTask(_ task: Task<Void, Never>, for id: String) {
        tasks[id] = task
    }

    func markRunning(_ id: String) {
        records[id]?.status = .running
    }

    func complete(_ id: String, result: String) {
        records[id]?.status = .completed
        records[id]?.result = result
        records[id]?.finishedAt = Date()
        tasks[id] = nil
        evictTerminalOverflow()
    }

    func fail(_ id: String, error: String) {
        records[id]?.status = .error
        records[id]?.error = error
        records[id]?.finishedAt = Date()
        tasks[id] = nil
        evictTerminalOverflow()
    }

    func stop(_ id: String, reason: ChatSpawnedAgentStopReason, partialResult: String?) {
        records[id]?.status = .stopped
        records[id]?.stopReason = reason
        records[id]?.result = partialResult
        records[id]?.finishedAt = Date()
        tasks[id] = nil
        evictTerminalOverflow()
    }

    func record(for id: String) -> ChatSpawnedAgentRecord? {
        records[id]
    }

    func allRecords() -> [ChatSpawnedAgentRecord] {
        order.compactMap { records[$0] }
    }

    func queueSteerMessage(_ message: String, for id: String) -> Bool {
        guard let status = records[id]?.status, status == .queued || status == .running else {
            return false
        }
        pendingSteerMessages[id, default: []].append(message)
        return true
    }

    func drainSteerMessages(for id: String) -> [String] {
        defer { pendingSteerMessages[id] = nil }
        return pendingSteerMessages[id] ?? []
    }

    /// Only cancels the task -- the record's own status/stopReason update happens
    /// when the cancelled run unwinds and calls `stop(_:reason:.cancelled...)`,
    /// same as any other stop reason.
    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    private func evictTerminalOverflow() {
        let terminalIDs = order.filter {
            switch records[$0]?.status {
            case .completed, .error, .stopped: true
            default: false
            }
        }
        guard terminalIDs.count > Self.maximumTrackedTerminalAgents else {
            return
        }
        for id in terminalIDs.prefix(terminalIDs.count - Self.maximumTrackedTerminalAgents) {
            records[id] = nil
            order.removeAll { $0 == id }
        }
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}
