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
            source: sourceName
        )
    }
}

struct ChatToolRequest {
    let definitions: [MLXChatToolDefinition]
    fileprivate let tools: [ChatAvailableTool]
    fileprivate let scope: ChatToolScope
    fileprivate let canEditImage: Bool

    func restricted(to allowedDefinitions: [MLXChatToolDefinition]) -> Self {
        Self(
            definitions: definitions.filter { allowedDefinitions.contains($0) },
            tools: tools, scope: scope, canEditImage: canEditImage
        )
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
                && ChatToolScope.projectToolNames.contains(name)
                && (previous.fileReadRootPath != settings.fileReadRootPath
                    || previous.fileWriteRootPath != settings.fileWriteRootPath)
            if !isAvailable(execution.tool, scope: execution.scope) || changedFileAccess {
                executions[id]?.revoked = true
                execution.task.cancel()
            }
        }
    }

    func prepareRequest(
        scope: ChatToolScope,
        canEditImage: Bool,
        activatedToolNames: Set<String>,
        mcpHost: (any ChatToolMCPHost)?
    ) -> ChatToolRequest {
        let tools = catalog(scope: scope, canEditImage: canEditImage, mcpHost: mcpHost)
        let definitions = ChatToolExposurePolicy.advertisedDefinitions(
            from: tools.map {
                ChatToolExposureCandidate(definition: $0.definition, exposureMode: $0.exposureMode)
            },
            activatedToolNames: activatedToolNames
        )
        return ChatToolRequest(
            definitions: definitions, tools: tools, scope: scope, canEditImage: canEditImage
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
            throw ChatToolAccessError.unavailable(name)
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
                    context.discoverableTools = self.catalog(
                        scope: request.scope, canEditImage: request.canEditImage, mcpHost: mcpHost
                    ).filter {
                        $0.exposureMode == .automatic
                            && $0.definition.function.name != ChatToolDiscoveryRegistry.toolName
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
                throw ChatToolAccessError.unavailable(name)
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
        guard isAvailable(tool, scope: request.scope),
            let current = catalog(
                scope: request.scope, canEditImage: request.canEditImage, mcpHost: mcpHost
            ).first(where: { $0.definition.function.name == name }),
            current.source == tool.source, current.definition == tool.definition
        else { throw ChatToolAccessError.unavailable(name) }
    }

    private func isAvailable(_ tool: ChatAvailableTool, scope: ChatToolScope) -> Bool {
        let name = tool.definition.function.name
        switch tool.source {
        case .custom(let custom):
            return settings.customTools.contains(custom)
                && settings.toolExposureMode(for: name, default: .automatic) != .off
        case .mcp(let server):
            guard settings.mcpServers.contains(server),
                settings.mcpServerExposureMode(for: server) != .off
            else { return false }
            return settings.toolExposureMode(
                for: name, default: settings.mcpServerExposureMode(for: server)
            ) != .off
        case .builtIn:
            guard settings.toolExposureMode(for: name) != .off else { return false }
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

    private func catalog(
        scope: ChatToolScope,
        canEditImage: Bool,
        mcpHost: (any ChatToolMCPHost)?
    ) -> [ChatAvailableTool] {
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
            for server in settings.mcpServers where settings.mcpServerExposureMode(for: server) != .off {
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
        let counts = Dictionary(grouping: tools, by: { $0.definition.function.name }).mapValues(\.count)
        return tools.filter {
            counts[$0.definition.function.name] == 1 && isAvailable($0, scope: scope)
        }
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
