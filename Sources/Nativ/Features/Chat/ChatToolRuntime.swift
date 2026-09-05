import Foundation
import NativServerKit

@MainActor
protocol ChatToolMCPHost: AnyObject {
    func toolDefinitions(forServer id: UUID) -> [MLXChatToolDefinition]
    func callTool(named name: String, argumentsJSON: String?) async throws -> String
}

extension MCPHostManager: ChatToolMCPHost {}

struct ChatAvailableTool: Equatable {
    enum Source: Equatable {
        case builtIn
        case custom(CustomTool)
        case mcp(MCPServerConfig)
    }

    let definition: MLXChatToolDefinition
    let title: String
    let source: Source
    let exposureMode: ToolExposureMode

    var discoveryCandidate: ChatToolDiscoveryCandidate {
        let sourceName: String = switch source {
        case .builtIn: "Built-in"
        case .custom: "Custom"
        case .mcp(let server): server.name
        }
        return ChatToolDiscoveryCandidate(
            name: definition.function.name,
            title: title,
            description: definition.function.description,
            source: sourceName,
            parameters: definition.function.parameters
        )
    }
}

struct ChatToolRequest {
    let definitions: [MLXChatToolDefinition]
    fileprivate let tools: [ChatAvailableTool]
    fileprivate let scope: ChatToolScope
    fileprivate let canEditImage: Bool
}

struct ChatToolSelection {
    private(set) var toolNames: [String]

    init(toolNames: [String] = []) {
        self.toolNames = toolNames
    }

    init(history: [ChatTranscriptMessage]) {
        let previousTurn = history.lastIndex(where: { $0.role == .user }).map { history[$0...] }
        var seen = Set<String>()
        toolNames = previousTurn?.reversed().compactMap { message in
            guard message.role == .tool, message.toolStatus == .succeeded,
                let name = message.toolName, name != ChatToolDiscoveryRegistry.toolName,
                seen.insert(name).inserted
            else { return nil }
            return name
        } ?? []
    }

    mutating func record(
        call: MLXChatToolCall,
        outcome: ChatToolExecutionOutcome,
        request: ChatToolRequest
    ) {
        guard let name = call.function?.name else { return }
        if name == ChatToolDiscoveryRegistry.toolName {
            if !outcome.activatedToolNames.isEmpty {
                toolNames = outcome.activatedToolNames.sorted()
            }
        } else if request.tools.contains(where: {
            $0.definition.function.name == name && $0.exposureMode == .automatic
        }) {
            toolNames.removeAll { $0 == name }
            toolNames.insert(name, at: 0)
        }
    }

    fileprivate func advertisedNames(in tools: [ChatAvailableTool]) -> Set<String> {
        let available = Set(tools.filter { $0.exposureMode == .automatic }.map { $0.definition.function.name })
        var seen = Set<String>()
        return Set(toolNames.filter { available.contains($0) && seen.insert($0).inserted }
            .prefix(ChatToolDiscoveryRegistry.maximumResults))
    }
}

enum ChatToolExecutionError: Error {
    case declined(String)
}

@MainActor
final class ChatToolRuntime {
    private struct Execution {
        let tool: ChatAvailableTool
        let scope: ChatToolScope
        let task: Task<ChatToolExecutionOutcome, Error>
        var revoked = false
    }

    private var settings: NativSettings
    private var executions: [UUID: Execution] = [:]

    init(settings: NativSettings = NativSettings()) {
        self.settings = settings
    }

    func updateSettings(_ settings: NativSettings) {
        let previous = self.settings
        self.settings = settings
        for (id, execution) in executions {
            let name = execution.tool.definition.function.name
            let changedFileAccess = !execution.scope.isProject
                && ((ChatReadFileToolRegistry.toolNames.contains(name)
                    && previous.fileReadRootPath != settings.fileReadRootPath)
                    || (ChatFileWriteToolRegistry.toolNames.contains(name)
                        && previous.fileWriteRootPath != settings.fileWriteRootPath))
            if !isAvailable(execution.tool, scope: execution.scope) || changedFileAccess {
                executions[id]?.revoked = true
                execution.task.cancel()
            }
        }
    }

    func prepareRequest(
        scope: ChatToolScope,
        canEditImage: Bool,
        selection: ChatToolSelection,
        mcpHost: (any ChatToolMCPHost)?
    ) -> ChatToolRequest {
        let tools = availableTools(scope: scope, canEditImage: canEditImage, mcpHost: mcpHost)
        let definitions = ChatToolExposurePolicy.advertisedDefinitions(
            from: tools.map {
                ChatToolExposureCandidate(definition: $0.definition, exposureMode: $0.exposureMode)
            },
            activatedToolNames: selection.advertisedNames(in: tools)
        )
        return ChatToolRequest(
            definitions: definitions, tools: tools, scope: scope, canEditImage: canEditImage
        )
    }

    func prepareRequest(
        allowing definitions: [MLXChatToolDefinition],
        mcpHost: (any ChatToolMCPHost)?
    ) -> ChatToolRequest {
        let scope = ChatToolScope.standalone(settings: settings)
        let tools = availableTools(scope: scope, canEditImage: false, mcpHost: mcpHost)
            .filter { definitions.contains($0.definition) }
        return ChatToolRequest(
            definitions: tools.map(\.definition), tools: tools, scope: scope, canEditImage: false
        )
    }

    func execute(
        call: MLXChatToolCall,
        request: ChatToolRequest,
        context: ChatToolExecutionContext,
        mcpHost: (any ChatToolMCPHost)? = nil,
        model: (any ChatModelSwitchingSurface)? = nil,
        requestApproval: @escaping @MainActor () async -> Bool = { false }
    ) async throws -> ChatToolExecutionOutcome {
        try Task.checkCancellation()
        let name = call.function?.name ?? "unknown"
        guard request.definitions.contains(where: { $0.function.name == name }),
            let tool = request.tools.first(where: { $0.definition.function.name == name })
        else {
            throw accessError(for: name, request: request, mcpHost: mcpHost)
        }
        try validate(tool, request: request, mcpHost: mcpHost)

        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            try self.validate(tool, request: request, mcpHost: mcpHost)
            var context = context
            context.fileReadRootPath = request.scope.isProject
                ? request.scope.fileReadRootPath : self.settings.fileReadRootPath
            context.fileWriteRootPath = request.scope.isProject
                ? request.scope.fileWriteRootPath : self.settings.fileWriteRootPath
            context.terminalDefaultWorkingDirectory = request.scope.terminalWorkingDirectory
            context.fileWriteApprovalGranted = false
            context.terminalApprovalGranted = false

            if let declinedPayload = try self.approvalRequirement(tool, call: call, context: context) {
                let approved = await requestApproval()
                try Task.checkCancellation()
                try self.validate(tool, request: request, mcpHost: mcpHost)
                guard approved else { throw ChatToolExecutionError.declined(declinedPayload) }
                context.fileWriteApprovalGranted = true
                context.terminalApprovalGranted = true
            }

            let result: ChatToolExecutionOutcome
            switch tool.source {
            case .custom(let custom):
                let content = try await CustomToolExecutor.execute(
                    custom, argumentsJSON: call.function?.arguments
                )
                result = ChatToolExecutionOutcome(content: content, attachments: [])
            case .mcp:
                guard let mcpHost else { throw ChatToolAccessError.unavailable(name) }
                let content = try await mcpHost.callTool(
                    named: name, argumentsJSON: call.function?.arguments
                )
                result = ChatToolExecutionOutcome(content: content, attachments: [])
            case .builtIn:
                if name == ChatSwitchModelToolRegistry.toolName {
                    guard let model else { throw ChatSwitchModelToolError.appModelUnavailable }
                    let content = try await ChatSwitchModelToolExecutor().execute(call: call, appModel: model)
                    result = ChatToolExecutionOutcome(content: content, attachments: [])
                } else {
                    let allowedNames = Set(request.tools.map(\.definition.function.name))
                    let available = self.availableTools(
                        scope: request.scope, canEditImage: request.canEditImage, mcpHost: mcpHost
                    ).filter {
                        $0.definition.function.name != ChatToolDiscoveryRegistry.toolName
                            && allowedNames.contains($0.definition.function.name)
                    }
                    let providedNames = Set(request.definitions.map(\.function.name))
                    context.availableTools = available.filter {
                        $0.exposureMode == .on && providedNames.contains($0.definition.function.name)
                    }.map(\.discoveryCandidate)
                    context.discoverableTools = available.filter {
                        $0.exposureMode == .automatic
                    }.map(\.discoveryCandidate)
                    result = try await ChatToolDispatcher.execute(call: call, context: context)
                }
            }
            try Task.checkCancellation()
            return result
        }
        executions[id] = Execution(tool: tool, scope: request.scope, task: task)
        defer { executions.removeValue(forKey: id) }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if executions[id]?.revoked == true {
                throw ChatToolAccessError.revoked(name)
            }
            throw error
        }
    }

    private func validate(
        _ tool: ChatAvailableTool,
        request: ChatToolRequest,
        mcpHost: (any ChatToolMCPHost)?
    ) throws {
        let name = tool.definition.function.name
        if isOff(tool) { throw ChatToolAccessError.disabled(name) }
        guard isAvailable(tool, scope: request.scope),
            let current = availableTools(
                scope: request.scope, canEditImage: request.canEditImage, mcpHost: mcpHost
            ).first(where: { $0.definition.function.name == name }),
            current.source == tool.source, current.definition == tool.definition
        else { throw ChatToolAccessError.unavailable(name) }
    }

    private func isAvailable(_ tool: ChatAvailableTool, scope: ChatToolScope) -> Bool {
        guard !isOff(tool) else { return false }
        let name = tool.definition.function.name
        switch tool.source {
        case .custom(let custom):
            return settings.customTools.contains(custom)
        case .mcp(let server):
            return settings.mcpServers.contains(server)
        case .builtIn:
            if scope.isProject, ChatToolScope.projectToolNames.contains(name) {
                return scope.projectToolsAreAvailable && settings.projectToolsEnabled
            }
            switch name {
            case ChatWebSearchToolRegistry.toolName:
                return ChatWebSearchToolRegistry.isConfigured()
            case ChatWebReadToolRegistry.toolName:
                return ChatWebReadToolRegistry.isConfigured()
            case ChatReadFileToolRegistry.toolName, ChatSearchFilesToolRegistry.toolName:
                return FileReadAccessPolicy.isConfigured(rootPath: settings.fileReadRootPath)
            case ChatFileWriteToolRegistry.writeToolName, ChatFileWriteToolRegistry.patchToolName:
                return FileWriteAccessPolicy.isConfigured(rootPath: settings.fileWriteRootPath)
            default:
                return true
            }
        }
    }

    private func isOff(_ tool: ChatAvailableTool) -> Bool {
        let name = tool.definition.function.name
        switch tool.source {
        case .builtIn:
            return settings.toolExposureMode(for: name) == .off
        case .custom:
            return settings.toolExposureMode(for: name, default: .automatic) == .off
        case .mcp(let original):
            guard let server = settings.mcpServers.first(where: { $0.id == original.id }) else { return false }
            let mode = settings.mcpServerExposureMode(for: server)
            return mode == .off || settings.toolExposureMode(for: name, default: mode) == .off
        }
    }

    private func accessError(
        for name: String, request: ChatToolRequest, mcpHost: (any ChatToolMCPHost)?
    ) -> ChatToolAccessError {
        let candidates = catalog(canEditImage: request.canEditImage, mcpHost: mcpHost)
            .filter { $0.definition.function.name == name }
        guard let tool = candidates.first else {
            return request.tools.contains { $0.definition.function.name == name }
                ? .unavailable(name) : .unknown(name)
        }
        guard candidates.count == 1 else { return .unavailable(name) }
        if isOff(tool) { return .disabled(name) }
        guard isAvailable(tool, scope: request.scope) else { return .unavailable(name) }
        if tool.exposureMode == .automatic,
            settings.toolExposureMode(for: ChatToolDiscoveryRegistry.toolName) != .off,
            request.tools.contains(where: { $0.definition.function.name == name }),
            request.definitions.contains(where: { $0.function.name == ChatToolDiscoveryRegistry.toolName }) {
            return .notDiscovered(name)
        }
        return .notAdvertised(name)
    }

    private func availableTools(
        scope: ChatToolScope,
        canEditImage: Bool,
        mcpHost: (any ChatToolMCPHost)?
    ) -> [ChatAvailableTool] {
        let tools = catalog(canEditImage: canEditImage, mcpHost: mcpHost)
        let counts = Dictionary(grouping: tools, by: { $0.definition.function.name }).mapValues(\.count)
        return tools.filter {
            counts[$0.definition.function.name] == 1 && isAvailable($0, scope: scope)
        }
    }

    private func catalog(canEditImage: Bool, mcpHost: (any ChatToolMCPHost)?) -> [ChatAvailableTool] {
        var tools = [ChatAvailableTool(
            definition: ChatToolDiscoveryRegistry.definition,
            title: "Tool Search", source: .builtIn,
            exposureMode: settings.toolExposureMode(for: ChatToolDiscoveryRegistry.toolName)
        )]
        tools += ChatToolRegistry.descriptors(canEditImage: canEditImage).map { descriptor in
            ChatAvailableTool(
                definition: descriptor.definition,
                title: descriptor.configuration?.displayName
                    ?? descriptor.definition.function.name.replacingOccurrences(of: "_", with: " "),
                source: .builtIn,
                exposureMode: settings.toolExposureMode(for: descriptor.definition.function.name)
            )
        }
        tools += settings.customTools.compactMap { custom in
            guard let definition = try? custom.definition() else { return nil }
            return ChatAvailableTool(
                definition: definition, title: custom.name, source: .custom(custom),
                exposureMode: settings.toolExposureMode(for: custom.toolName, default: .automatic)
            )
        }
        if let mcpHost {
            for server in settings.mcpServers {
                tools += mcpHost.toolDefinitions(forServer: server.id).map { definition in
                    ChatAvailableTool(
                        definition: definition, title: definition.function.name, source: .mcp(server),
                        exposureMode: settings.toolExposureMode(
                            for: definition.function.name, default: settings.mcpServerExposureMode(for: server)
                        )
                    )
                }
            }
        }
        return tools
    }

    private func approvalRequirement(
        _ tool: ChatAvailableTool,
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) throws -> String? {
        switch tool.source {
        case .custom(let custom) where custom.kind == .script:
            return #"{"ok":false,"error":"The user declined to run this script tool."}"#
        case .builtIn:
            switch tool.definition.function.name {
            case ChatTerminalToolRegistry.toolName:
                try ChatTerminalToolExecutor().preflight(
                    call: call, defaultWorkingDirectory: context.terminalDefaultWorkingDirectory
                )
                return ChatTerminalToolExecutor().declinedPayload()
            case ChatSwitchModelToolRegistry.toolName:
                return ChatSwitchModelToolExecutor().declinedPayload()
            default:
                return ChatFileWriteApprovalPolicy.requiresApproval(call: call, rootPath: context.fileWriteRootPath)
                    ? ChatFileWriteToolExecutor().declinedPayload() : nil
            }
        default:
            return nil
        }
    }
}
