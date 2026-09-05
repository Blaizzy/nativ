import Foundation

enum ChatTranscriptItem: Identifiable, Equatable {
    case message(ChatTranscriptMessage)
    case agentTurn(ChatAgentTurnPresentation)

    var id: UUID {
        switch self {
        case .message(let message):
            message.id
        case .agentTurn(let turn):
            turn.id
        }
    }
}

enum ChatTranscriptPresentation {
    static func items(from messages: [ChatTranscriptMessage]) -> [ChatTranscriptItem] {
        var items: [ChatTranscriptItem] = []
        var pendingAgentMessages: [ChatTranscriptMessage] = []

        func appendPendingAgentMessages() {
            guard !pendingAgentMessages.isEmpty else {
                return
            }

            if pendingAgentMessages.contains(where: { $0.role == .tool }) {
                items.append(
                    .agentTurn(ChatAgentTurnPresentation(messages: pendingAgentMessages))
                )
            } else {
                items.append(contentsOf: pendingAgentMessages.map(ChatTranscriptItem.message))
            }
            pendingAgentMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            switch message.role {
            case .assistant, .tool:
                pendingAgentMessages.append(message)
            case .user, .error:
                appendPendingAgentMessages()
                items.append(.message(message))
            }
        }

        appendPendingAgentMessages()
        return items
    }
}

struct ChatAgentTurnPresentation: Identifiable, Equatable {
    let id: UUID
    let messages: [ChatTranscriptMessage]

    init(messages: [ChatTranscriptMessage]) {
        precondition(!messages.isEmpty)
        id = messages[0].id
        self.messages = messages
    }

    var assistantMessages: [ChatTranscriptMessage] {
        messages.filter { $0.role == .assistant }
    }

    var toolMessages: [ChatTranscriptMessage] {
        messages.filter { $0.role == .tool }
    }

    var finalAssistantMessage: ChatTranscriptMessage? {
        assistantMessages.last(where: { $0.toolCalls.isEmpty })
    }

    var modelID: String? {
        finalAssistantMessage?.modelID ?? assistantMessages.last?.modelID
    }

    var reasoningContent: String {
        assistantMessages
            .map(\.reasoningContent)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var thinkingDuration: TimeInterval? {
        let durations = assistantMessages.compactMap { message -> TimeInterval? in
            guard !message.reasoningContent.isEmpty else {
                return nil
            }
            return message.thinkingDuration
        }
        guard !durations.isEmpty else {
            return nil
        }
        return durations.reduce(0, +)
    }

    var isThinking: Bool {
        assistantMessages.contains { message in
            message.isStreaming
                && message.content.isEmpty
                && (message.isThinkingEnabled || !message.reasoningContent.isEmpty)
        }
    }

    var isAssistantStreaming: Bool {
        assistantMessages.contains(where: \.isStreaming)
    }

    var intermediateAssistantMessages: [ChatTranscriptMessage] {
        let finalID = finalAssistantMessage?.id
        return assistantMessages.filter { message in
            message.id != finalID && !message.content.isEmpty
        }
    }

    var toolUsage: ChatToolUsageSummary {
        ChatToolUsageSummary(messages: toolMessages)
    }
}

struct ChatToolUsageSummary: Equatable {
    let groups: [ChatToolUsageGroup]

    init(messages: [ChatTranscriptMessage]) {
        var orderedKinds: [ChatToolUsageKind] = []
        var messagesByKind: [ChatToolUsageKind: [ChatTranscriptMessage]] = [:]

        for message in messages {
            let kind = ChatToolUsageKind(toolName: message.toolName)
            if messagesByKind[kind] == nil {
                orderedKinds.append(kind)
            }
            messagesByKind[kind, default: []].append(message)
        }

        groups = orderedKinds.compactMap { kind in
            guard let messages = messagesByKind[kind] else {
                return nil
            }
            return ChatToolUsageGroup(kind: kind, messages: messages)
        }
    }

    var text: String {
        let value = groups.map(\.phrase).joined(separator: ", ")
        guard let first = value.first else {
            return ""
        }
        return first.uppercased() + value.dropFirst()
    }

    var isActive: Bool {
        groups.contains { group in
            group.messages.contains { message in
                message.toolStatus == .preparing
                    || message.toolStatus == .running
                    || (message.toolStatus == nil && message.isStreaming)
            }
        }
    }

    var requiresInteraction: Bool {
        groups.contains { group in
            group.messages.contains { message in
                message.toolStatus == .awaitingConsent
                    || message.toolStatus == .awaitingImageModelSelection
            }
        }
    }

    var hasFailure: Bool {
        groups.contains { group in
            group.messages.contains { $0.toolStatus == .failed }
        }
    }

    var hasNonSuccess: Bool {
        groups.contains { group in
            group.messages.contains { message in
                message.toolStatus == .failed
                    || message.toolStatus == .cancelled
                    || message.toolStatus == .declined
            }
        }
    }
}

struct ChatToolUsageGroup: Identifiable, Equatable {
    enum State: Equatable {
        case active
        case waiting
        case succeeded
        case failed
        case cancelled
        case declined
    }

    let kind: ChatToolUsageKind
    let messages: [ChatTranscriptMessage]

    var id: UUID {
        messages[0].id
    }

    var state: State {
        if messages.contains(where: {
            $0.toolStatus == .awaitingConsent
                || $0.toolStatus == .awaitingImageModelSelection
        }) {
            return .waiting
        }
        if messages.contains(where: { $0.toolStatus == .failed }) {
            return .failed
        }
        if messages.contains(where: {
            $0.toolStatus == .preparing
                || $0.toolStatus == .running
                || ($0.toolStatus == nil && $0.isStreaming)
        }) {
            return .active
        }
        if messages.contains(where: { $0.toolStatus == .declined }) {
            return .declined
        }
        if messages.contains(where: { $0.toolStatus == .cancelled }) {
            return .cancelled
        }
        return .succeeded
    }

    var phrase: String {
        kind.phrase(count: messages.count, state: state)
    }
}

enum ChatToolUsageKind: Hashable {
    case toolDiscovery
    case imageGeneration
    case imageEdit
    case systemStats
    case modelLibrary
    case serverStats
    case modelSwitch
    case webSearch
    case webRead
    case fileRead
    case fileSearch
    case fileWrite
    case filePatch
    case terminal
    case named(String)

    init(toolName: String?) {
        switch toolName {
        case ChatToolDiscoveryRegistry.toolName:
            self = .toolDiscovery
        case ChatImageToolRegistry.generateToolName:
            self = .imageGeneration
        case ChatImageToolRegistry.editToolName:
            self = .imageEdit
        case ChatSystemMonitorToolRegistry.toolName:
            self = .systemStats
        case ChatModelLibraryToolRegistry.toolName:
            self = .modelLibrary
        case ChatServerStatsToolRegistry.toolName:
            self = .serverStats
        case ChatSwitchModelToolRegistry.toolName:
            self = .modelSwitch
        case ChatWebSearchToolRegistry.toolName:
            self = .webSearch
        case ChatWebReadToolRegistry.toolName:
            self = .webRead
        case ChatReadFileToolRegistry.toolName:
            self = .fileRead
        case ChatSearchFilesToolRegistry.toolName:
            self = .fileSearch
        case ChatFileWriteToolRegistry.writeToolName:
            self = .fileWrite
        case ChatFileWriteToolRegistry.patchToolName:
            self = .filePatch
        case ChatTerminalToolRegistry.toolName:
            self = .terminal
        case .some(let toolName):
            self = .named(Self.displayName(for: toolName))
        case nil:
            self = .named("tool")
        }
    }

    func phrase(count: Int, state: ChatToolUsageGroup.State) -> String {
        switch state {
        case .succeeded:
            completedPhrase(count: count)
        case .active:
            activePhrase(count: count)
        case .waiting:
            waitingPhrase(count: count)
        case .failed:
            "\(activityName(count: count)) failed"
        case .cancelled:
            "\(activityName(count: count)) canceled"
        case .declined:
            "\(activityName(count: count)) declined"
        }
    }

    private func completedPhrase(count: Int) -> String {
        switch self {
        case .toolDiscovery:
            "found available tools"
        case .imageGeneration:
            count == 1 ? "generated an image" : "generated images"
        case .imageEdit:
            count == 1 ? "edited an image" : "edited images"
        case .systemStats:
            "checked system stats"
        case .modelLibrary:
            "listed downloaded models"
        case .serverStats:
            "checked server stats"
        case .modelSwitch:
            "switched models"
        case .webSearch:
            "searched the web"
        case .webRead:
            count == 1 ? "read a web page" : "read web pages"
        case .fileRead:
            count == 1 ? "read a file" : "read files"
        case .fileSearch:
            "searched files"
        case .fileWrite:
            count == 1 ? "wrote a file" : "wrote files"
        case .filePatch:
            count == 1 ? "patched a file" : "patched files"
        case .terminal:
            count == 1 ? "ran a command" : "ran commands"
        case .named(let name):
            count == 1 ? "used \(name)" : "used \(name) \(count) times"
        }
    }

    private func activePhrase(count: Int) -> String {
        switch self {
        case .toolDiscovery:
            "finding available tools…"
        case .imageGeneration:
            count == 1 ? "generating an image…" : "generating images…"
        case .imageEdit:
            count == 1 ? "editing an image…" : "editing images…"
        case .systemStats:
            "checking system stats…"
        case .modelLibrary:
            "listing downloaded models…"
        case .serverStats:
            "checking server stats…"
        case .modelSwitch:
            "switching models…"
        case .webSearch:
            "searching the web…"
        case .webRead:
            count == 1 ? "reading a web page…" : "reading web pages…"
        case .fileRead:
            count == 1 ? "reading a file…" : "reading files…"
        case .fileSearch:
            "searching files…"
        case .fileWrite:
            count == 1 ? "writing a file…" : "writing files…"
        case .filePatch:
            count == 1 ? "patching a file…" : "patching files…"
        case .terminal:
            count == 1 ? "running a command…" : "running commands…"
        case .named(let name):
            "using \(name)…"
        }
    }

    private func waitingPhrase(count: Int) -> String {
        switch self {
        case .toolDiscovery:
            "waiting to find available tools"
        case .imageGeneration:
            "waiting to generate an image"
        case .imageEdit:
            "waiting to edit an image"
        case .modelSwitch:
            "waiting to switch models"
        case .fileWrite:
            count == 1 ? "waiting to write a file" : "waiting to write files"
        case .filePatch:
            count == 1 ? "waiting to patch a file" : "waiting to patch files"
        case .terminal:
            count == 1 ? "waiting to run a command" : "waiting to run commands"
        default:
            "waiting for \(activityName(count: count))"
        }
    }

    private func activityName(count: Int) -> String {
        switch self {
        case .toolDiscovery:
            "tool search"
        case .imageGeneration:
            count == 1 ? "image generation" : "image generations"
        case .imageEdit:
            count == 1 ? "image edit" : "image edits"
        case .systemStats:
            "system stats check"
        case .modelLibrary:
            "model listing"
        case .serverStats:
            "server stats check"
        case .modelSwitch:
            count == 1 ? "model switch" : "model switches"
        case .webSearch:
            "web search"
        case .webRead:
            count == 1 ? "web read" : "web reads"
        case .fileRead:
            count == 1 ? "file read" : "file reads"
        case .fileSearch:
            count == 1 ? "file search" : "file searches"
        case .fileWrite:
            count == 1 ? "file write" : "file writes"
        case .filePatch:
            count == 1 ? "file patch" : "file patches"
        case .terminal:
            count == 1 ? "command" : "commands"
        case .named(let name):
            count == 1 ? name : "\(name) uses"
        }
    }

    private static func displayName(for toolName: String) -> String {
        var name = toolName
        if name.hasPrefix("mcp__") {
            let body = name.dropFirst("mcp__".count)
            if let separator = body.range(of: "__") {
                name = String(body[separator.upperBound...])
            }
        }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}
