import Foundation
import NativServerKit

typealias ChatImageModelSelectionHandler =
    @MainActor @Sendable (
        ChatImageModelSelectionRequest
    ) async throws -> String

struct ChatToolExecutionContext: Sendable {
    let imageGenerationModelID: String?
    let baseURL: URL
    let apiKey: String?
    let imageReferences: [ChatImageAttachment]
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    var huggingFaceToken: String? = nil
    var analyticsDatabaseURL: URL? = nil
    var imageToolDependencies = ChatImageToolDependencies.live
    var fileReadRootPath: String? = nil
    var fileReadTracker: ChatReadFileTracker? = nil
    var fileReadMaximumResultCharacters = ChatReadFileToolRegistry.defaultMaximumResultCharacters
    var fileReadToolDependencies = ChatReadFileToolDependencies.live
    var fileSearchTracker: ChatSearchFilesTracker? = nil
    var fileSearchMaximumResultCharacters =
        ChatSearchFilesToolRegistry.defaultMaximumResultCharacters
    var fileSearchToolDependencies = ChatSearchFilesToolDependencies.live
    var fileWriteRootPath: String? = nil
    var fileWriteApprovalGranted = false
    var fileOperationRunID = UUID()
    var fileMutationState = FileMutationState.shared
    var fileWriteToolDependencies = ChatFileWriteToolDependencies.live
    var terminalApprovalGranted = false
    var terminalDefaultWorkingDirectory: String? = nil
    var terminalToolDependencies = ChatTerminalToolDependencies.live
    var discoverableTools: [ChatToolDiscoveryCandidate] = []
    var imageModelSelection: ChatImageModelSelectionHandler? = nil
    var imageExecutionWillStart: (@MainActor @Sendable (String) -> Void)? = nil
}

struct ChatToolExecutionOutcome: Sendable {
    let content: String
    let attachments: [ChatImageAttachment]
    let activatedToolNames: Set<String>

    init(
        content: String,
        attachments: [ChatImageAttachment],
        activatedToolNames: Set<String> = []
    ) {
        self.content = content
        self.attachments = attachments
        self.activatedToolNames = activatedToolNames
    }
}

enum ChatToolRoundGate {
    static let maximumRounds = 32

    static func advertisesTools(atRound round: Int) -> Bool {
        round < maximumRounds
    }
}

enum ChatNativeToolConfiguration: Hashable {
    case webSearch
    case webRead
    case fileRead
    case fileWrite

    var displayName: String {
        switch self {
        case .webSearch:
            "Web Search"
        case .webRead:
            "Web Read"
        case .fileRead:
            "File Read"
        case .fileWrite:
            "File Write"
        }
    }

    var isConfigured: Bool {
        switch self {
        case .webSearch:
            ChatWebSearchToolRegistry.isConfigured()
        case .webRead:
            ChatWebReadToolRegistry.isConfigured()
        case .fileRead:
            FileReadAccessPolicy.isConfigured(
                rootPath: NativSettings.load().fileReadRootPath
            )
        case .fileWrite:
            FileWriteAccessPolicy.isConfigured(
                rootPath: NativSettings.load().fileWriteRootPath
            )
        }
    }

    var systemImage: String {
        switch self {
        case .webSearch:
            "globe"
        case .webRead:
            "doc.text.magnifyingglass"
        case .fileRead:
            "doc.text"
        case .fileWrite:
            "square.and.pencil"
        }
    }

    var toolNames: [String] {
        switch self {
        case .webSearch:
            [ChatWebSearchToolRegistry.toolName]
        case .webRead:
            [ChatWebReadToolRegistry.toolName]
        case .fileRead:
            ChatReadFileToolRegistry.toolNames
        case .fileWrite:
            ChatFileWriteToolRegistry.toolNames
        }
    }
}

struct ChatNativeToolDescriptor {
    let definition: MLXChatToolDefinition
    let displayDescription: String
    let configuration: ChatNativeToolConfiguration?

    var exposureToolNames: [String] {
        if let configuration {
            return configuration.toolNames
        }
        if definition.function.name == ChatImageToolRegistry.generateToolName {
            return [
                ChatImageToolRegistry.generateToolName,
                ChatImageToolRegistry.editToolName,
            ]
        }
        return [definition.function.name]
    }
}

struct ChatToolDiscoveryCandidate: Equatable, Sendable {
    let name: String
    let title: String
    let description: String
    let source: String
}

struct ChatToolExposureCandidate: Equatable, Sendable {
    let definition: MLXChatToolDefinition
    let exposureMode: ToolExposureMode
}

enum ChatToolExposurePolicy {
    static func advertisedDefinitions(
        from candidates: [ChatToolExposureCandidate],
        activatedToolNames: Set<String>
    ) -> [MLXChatToolDefinition] {
        let discoveryCandidate = candidates.first {
            $0.definition.function.name == ChatToolDiscoveryRegistry.toolName
        }
        let callableCandidates = candidates.filter {
            $0.definition.function.name != ChatToolDiscoveryRegistry.toolName
        }
        var definitions = callableCandidates.compactMap { candidate in
            let name = candidate.definition.function.name
            return candidate.exposureMode == .on
                || (candidate.exposureMode == .automatic && activatedToolNames.contains(name))
                ? candidate.definition
                : nil
        }
        if let discoveryCandidate {
            let shouldAdvertise = switch discoveryCandidate.exposureMode {
            case .off:
                false
            case .automatic:
                callableCandidates.contains { $0.exposureMode == .automatic }
            case .on:
                true
            }
            if shouldAdvertise {
                definitions.append(discoveryCandidate.definition)
            }
        }
        return definitions
    }
}

enum ChatToolDiscoveryRegistry {
    static let toolName = "tool_search"
    static let maximumResults = 3
    static let maximumResultDescriptionCharacters = 240

    static let definition = MLXChatToolDefinition(
        function: MLXChatFunctionDefinition(
            name: toolName,
            description:
                "Find tools that are available in Auto mode but not currently shown. Use this when the user asks for a capability that the visible tools do not cover. Matching tools become available after this call.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string(
                            "A short capability query, such as search Git history, query SQLite, or generate an image."
                        ),
                    ])
                ]),
                "required": .array([.string("query")]),
            ])
        )
    )

    static func search(
        _ query: String,
        candidates: [ChatToolDiscoveryCandidate],
        limit: Int = maximumResults
    ) -> [ChatToolDiscoveryCandidate] {
        let normalizedQuery = normalized(query)
        let queryTerms = terms(in: normalizedQuery)
        guard !normalizedQuery.isEmpty, !queryTerms.isEmpty else { return [] }

        return candidates.compactMap { candidate in
            let searchable = normalized(
                "\(candidate.name) \(candidate.title) \(candidate.description) \(candidate.source)"
            )
            let searchableTerms = terms(in: searchable)
            var score = searchable.contains(normalizedQuery) ? 100 : 0
            for term in queryTerms {
                if searchableTerms.contains(term) {
                    score += 20
                } else if searchableTerms.contains(where: {
                    ($0.count >= 4 && term.hasPrefix($0))
                        || (term.count >= 4 && $0.hasPrefix(term))
                }) {
                    score += 14
                } else if searchable.contains(term) {
                    score += 8
                }
            }
            return score == 0 ? nil : (candidate, score)
        }
        .sorted {
            if $0.1 == $1.1 {
                return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
            }
            return $0.1 > $1.1
        }
        .prefix(max(1, min(limit, maximumResults)))
        .map(\.0)
    }

    static func matches(
        argumentsJSON: String?,
        candidates: [ChatToolDiscoveryCandidate]
    ) throws -> [ChatToolDiscoveryCandidate] {
        guard let argumentsJSON,
            let data = argumentsJSON.data(using: .utf8),
            let request = try? JSONDecoder().decode(ChatToolDiscoveryRequest.self, from: data),
            !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ChatToolDiscoveryError.invalidArguments
        }
        return search(request.query, candidates: candidates)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func terms(in value: String) -> Set<String> {
        let ignored = Set([
            "a", "an", "and", "can", "find", "for", "i", "me", "my", "need", "of", "or",
            "the", "to", "tool", "tools", "use", "want", "with",
        ])
        return Set(
            value.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !ignored.contains($0) }
        )
    }

    static func resultDescription(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumResultDescriptionCharacters else { return trimmed }
        return String(trimmed.prefix(maximumResultDescriptionCharacters)) + "…"
    }
}

enum ChatToolRegistry {
    static func definitions(canEditImage: Bool) -> [MLXChatToolDefinition] {
        descriptors(canEditImage: canEditImage).map(\.definition)
    }

    static func descriptors(canEditImage: Bool) -> [ChatNativeToolDescriptor] {
        var tools = ChatImageToolRegistry.definitions(canEdit: canEditImage).map {
            ChatNativeToolDescriptor(
                definition: $0,
                displayDescription: $0.function.name == ChatImageToolRegistry.editToolName
                    ? "Edit an attached image by describing the changes."
                    : "Create an image from a written description.",
                configuration: nil
            )
        }
        tools += ChatModelLibraryToolRegistry.definitions().map {
            ChatNativeToolDescriptor(
                definition: $0,
                displayDescription: "List the models downloaded on this device.",
                configuration: nil
            )
        }
        tools += ChatSwitchModelToolRegistry.definitions().map {
            ChatNativeToolDescriptor(
                definition: $0,
                displayDescription: "Change which model this chat uses.",
                configuration: nil
            )
        }
        tools += ChatSystemMonitorToolRegistry.definitions().map {
            ChatNativeToolDescriptor(
                definition: $0,
                displayDescription: "Check this device’s CPU, GPU, memory, and disk usage.",
                configuration: nil
            )
        }
        tools += ChatServerStatsToolRegistry.definitions().map {
            ChatNativeToolDescriptor(
                definition: $0,
                displayDescription: "See the server’s speed, requests, and token usage.",
                configuration: nil
            )
        }
        tools.append(
            ChatNativeToolDescriptor(
                definition: ChatReadFileToolRegistry.definition,
                displayDescription: "Read and search files in the folder you authorize.",
                configuration: .fileRead
            ))
        tools.append(
            ChatNativeToolDescriptor(
                definition: ChatSearchFilesToolRegistry.definition,
                displayDescription: "Read and search files in the folder you authorize.",
                configuration: .fileRead
            ))
        tools += ChatFileWriteToolRegistry.definitions.map {
            ChatNativeToolDescriptor(
                definition: $0,
                displayDescription: "Create and edit files in the folder you authorize.",
                configuration: .fileWrite
            )
        }
        tools.append(
            ChatNativeToolDescriptor(
                definition: ChatTerminalToolRegistry.definition,
                displayDescription:
                    "Run approved shell commands locally on this Mac.",
                configuration: nil
            ))
        tools.append(
            ChatNativeToolDescriptor(
                definition: ChatWebSearchToolRegistry.definition,
                displayDescription: "Search the web for current information and sources.",
                configuration: .webSearch
            ))
        tools.append(
            ChatNativeToolDescriptor(
                definition: ChatWebReadToolRegistry.definition,
                displayDescription: "Read and find relevant information on public web pages.",
                configuration: .webRead
            ))
        return tools
    }
}

enum ChatUnknownToolError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}

enum ChatToolAccessError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            "The tool \(name) is Off, unavailable, or has not been discovered for this request."
        }
    }
}

private struct ChatToolDiscoveryRequest: Decodable {
    let query: String
}

private struct ChatToolDiscoveryMatch: Encodable {
    let name: String
    let title: String
    let description: String
    let source: String
}

private struct ChatToolDiscoveryPayload: Encodable {
    let ok: Bool
    let matches: [ChatToolDiscoveryMatch]
    let message: String
}

private enum ChatToolDiscoveryError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        "tool_search requires a non-empty query."
    }
}

private struct ChatUnknownToolResultPayload: Encodable {
    let ok: Bool
    let error: String?
}

enum ChatToolDispatcher {
    private typealias Handler =
        @Sendable (
            MLXChatToolCall,
            ChatToolExecutionContext
        ) async throws -> ChatToolExecutionOutcome
    private typealias FailureHandler = @Sendable (String, Error) -> String

    private static let handlers: [String: Handler] = [
        ChatToolDiscoveryRegistry.toolName: { call, context in
            try await executeToolDiscovery(call: call, context: context)
        },
        ChatImageToolRegistry.generateToolName: { call, context in
            try await executeImageTool(call: call, context: context)
        },
        ChatImageToolRegistry.editToolName: { call, context in
            try await executeImageTool(call: call, context: context)
        },
        ChatSystemMonitorToolRegistry.toolName: { call, context in
            try await executeSystemMonitorTool(call: call, context: context)
        },
        ChatModelLibraryToolRegistry.toolName: { call, context in
            try await executeModelLibraryTool(call: call, context: context)
        },
        ChatServerStatsToolRegistry.toolName: { call, context in
            try await executeServerStatsTool(call: call, context: context)
        },
        ChatWebSearchToolRegistry.toolName: { call, context in
            try await executeWebSearchTool(call: call, context: context)
        },
        ChatWebReadToolRegistry.toolName: { call, context in
            try await executeWebReadTool(call: call, context: context)
        },
        ChatReadFileToolRegistry.toolName: { call, context in
            try await executeReadFileTool(call: call, context: context)
        },
        ChatSearchFilesToolRegistry.toolName: { call, context in
            try await executeSearchFilesTool(call: call, context: context)
        },
        ChatFileWriteToolRegistry.writeToolName: { call, context in
            try await executeFileWriteTool(call: call, context: context)
        },
        ChatFileWriteToolRegistry.patchToolName: { call, context in
            try await executeFileWriteTool(call: call, context: context)
        },
        ChatTerminalToolRegistry.toolName: { call, context in
            try await executeTerminalTool(call: call, context: context)
        },
    ]

    private static let failureHandlers: [String: FailureHandler] = [
        ChatToolDiscoveryRegistry.toolName: { _, error in
            discoveryFailurePayload(error: error)
        },
        ChatImageToolRegistry.generateToolName: { name, error in
            failurePayloadForImageTool(name: name, error: error)
        },
        ChatImageToolRegistry.editToolName: { name, error in
            failurePayloadForImageTool(name: name, error: error)
        },
        ChatSystemMonitorToolRegistry.toolName: { name, error in
            ChatSystemMonitorToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatModelLibraryToolRegistry.toolName: { name, error in
            ChatModelLibraryToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatServerStatsToolRegistry.toolName: { name, error in
            ChatServerStatsToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatSwitchModelToolRegistry.toolName: { name, error in
            ChatSwitchModelToolExecutor().failurePayload(operation: name, error: error)
        },
        ChatWebSearchToolRegistry.toolName: { _, error in
            ChatWebSearchToolExecutor().failurePayload(error: error)
        },
        ChatWebReadToolRegistry.toolName: { _, error in
            ChatWebReadToolExecutor().failurePayload(error: error)
        },
        ChatReadFileToolRegistry.toolName: { _, error in
            ChatReadFileToolExecutor().failurePayload(error: error)
        },
        ChatSearchFilesToolRegistry.toolName: { _, error in
            ChatSearchFilesToolExecutor().failurePayload(error: error)
        },
        ChatFileWriteToolRegistry.writeToolName: { _, error in
            ChatFileWriteToolExecutor().failurePayload(error: error)
        },
        ChatFileWriteToolRegistry.patchToolName: { _, error in
            ChatFileWriteToolExecutor().failurePayload(error: error)
        },
        ChatTerminalToolRegistry.toolName: { _, error in
            ChatTerminalToolExecutor().failurePayload(error: error)
        },
    ]

    static func execute(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        guard let name = call.function?.name, let handler = handlers[name] else {
            throw ChatUnknownToolError.unknownTool(call.function?.name ?? "unknown")
        }
        return try await handler(call, context)
    }

    static func failurePayload(toolName: String?, error: Error) -> String {
        guard let toolName, let handler = failureHandlers[toolName] else {
            return unknownToolFailurePayload(error: error)
        }
        return handler(toolName, error)
    }

    private static func unknownToolFailurePayload(error: Error) -> String {
        let payload = ChatUnknownToolResultPayload(ok: false, error: error.localizedDescription)
        return (try? encodedPayload(payload)) ?? #"{"ok":false,"error":"Unknown tool."}"#
    }

    private static func encodedPayload(_ payload: ChatUnknownToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func executeImageTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let imageRequest = try ChatImageToolRequest(
            call: call,
            hasImageReference: !context.imageReferences.isEmpty
        )
        let availableModels = try await context.imageToolDependencies.discoverModels(
            imageRequest.operation,
            context.modelSearchPath,
            context.additionalModelSearchPaths,
            context.huggingFaceToken,
            context.imageGenerationModelID
        )
        let imageModelID: String
        switch ChatImageModelSelection.resolve(
            operation: imageRequest.operation,
            selectedModelID: context.imageGenerationModelID,
            availableModels: availableModels
        ) {
        case .selected(let model):
            imageModelID = model.modelID
        case .selectionRequired(let selectionRequest):
            guard let requestSelection = context.imageModelSelection else {
                throw selectionRequest.models.isEmpty
                    ? ChatImageToolError.noCompatibleModels(imageRequest.operation)
                    : ChatImageToolError.modelSelectionUnavailable(imageRequest.operation)
            }
            let selectedModelID = try await requestSelection(selectionRequest)
            guard
                let selectedModel = ChatImageModelSelection.selectedModel(
                    withID: selectedModelID,
                    from: selectionRequest
                )
            else {
                throw ChatImageToolError.modelSelectionUnavailable(imageRequest.operation)
            }
            imageModelID = selectedModel.modelID
        }
        await context.imageExecutionWillStart?(imageModelID)
        let result = try await context.imageToolDependencies.execute(
            imageRequest,
            imageModelID,
            context.baseURL,
            context.apiKey,
            context.imageReferences
        )
        return ChatToolExecutionOutcome(
            content: result.content,
            attachments: result.attachments
        )
    }

    private static func executeToolDiscovery(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let matches = try ChatToolDiscoveryRegistry.matches(
            argumentsJSON: call.function?.arguments,
            candidates: context.discoverableTools
        )
        let payload = ChatToolDiscoveryPayload(
            ok: true,
            matches: matches.map {
                ChatToolDiscoveryMatch(
                    name: $0.name,
                    title: $0.title,
                    description: ChatToolDiscoveryRegistry.resultDescription($0.description),
                    source: $0.source
                )
            },
            message: matches.isEmpty
                ? "No matching Auto tools were found."
                : "Matching tools are now available. Call the best match by name in the next step."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ChatToolExecutionOutcome(
            content: String(decoding: try encoder.encode(payload), as: UTF8.self),
            attachments: [],
            activatedToolNames: Set(matches.map(\.name))
        )
    }

    private static func discoveryFailurePayload(error: Error) -> String {
        let payload = ChatToolDiscoveryPayload(
            ok: false,
            matches: [],
            message: error.localizedDescription
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(payload), as: UTF8.self))
            ?? #"{"matches":[],"message":"Tool search failed.","ok":false}"#
    }

    private static func executeSystemMonitorTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatSystemMonitorToolExecutor().execute(call: call)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeModelLibraryTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatModelLibraryToolExecutor().execute(call: call, context: context)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeServerStatsTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try ChatServerStatsToolExecutor().execute(call: call, context: context)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeWebSearchTool(
        call: MLXChatToolCall,
        context _: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatWebSearchToolExecutor().execute(call: call)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeWebReadTool(
        call: MLXChatToolCall,
        context _: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatWebReadToolExecutor().execute(call: call)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeReadFileTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatReadFileToolExecutor().execute(
            call: call,
            context: context
        )
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeSearchFilesTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatSearchFilesToolExecutor().execute(
            call: call,
            context: context
        )
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeFileWriteTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatFileWriteToolExecutor().execute(call: call, context: context)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func executeTerminalTool(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        let content = try await ChatTerminalToolExecutor(
            dependencies: context.terminalToolDependencies
        ).execute(call: call, context: context)
        return ChatToolExecutionOutcome(content: content, attachments: [])
    }

    private static func failurePayloadForImageTool(name: String, error: Error) -> String {
        ChatImageToolExecutor().failurePayload(operation: name, error: error)
    }
}

@MainActor
final class ChatToolConsentGate {
    private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var pendingCount: Int {
        pending.count
    }

    func confirm(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(returning: true)
    }

    func deny(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(returning: false)
    }

    func awaitDecision(for id: UUID) async -> Bool {
        let denyRequest: @MainActor @Sendable () -> Void = { [weak self] in
            self?.deny(id)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                pending[id] = continuation
                if Task.isCancelled {
                    pending.removeValue(forKey: id)?.resume(returning: false)
                }
            }
        } onCancel: {
            Task { @MainActor in
                denyRequest()
            }
        }
    }
}

enum ChatToolConsentOutcome: Equatable {
    case cancelled
    case declined
    case approved
}

enum ChatToolConsentRouter {
    static func outcome(approved: Bool, isCancelled: Bool) -> ChatToolConsentOutcome {
        if isCancelled {
            return .cancelled
        }
        return approved ? .approved : .declined
    }
}

enum ChatToolPresentation {
    static func title(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch toolName {
        case ChatToolDiscoveryRegistry.toolName:
            return toolDiscoveryTitle(status: status)
        case ChatImageToolRegistry.generateToolName:
            return imageTitle(isEdit: false, status: status)
        case ChatImageToolRegistry.editToolName:
            return imageTitle(isEdit: true, status: status)
        case ChatSystemMonitorToolRegistry.toolName:
            return systemMonitorTitle(status: status)
        case ChatModelLibraryToolRegistry.toolName:
            return modelLibraryTitle(status: status)
        case ChatServerStatsToolRegistry.toolName:
            return serverStatsTitle(status: status)
        case ChatSwitchModelToolRegistry.toolName:
            return switchModelTitle(status: status)
        case ChatWebSearchToolRegistry.toolName:
            return webSearchTitle(status: status)
        case ChatWebReadToolRegistry.toolName:
            return webReadTitle(status: status)
        case ChatReadFileToolRegistry.toolName:
            return readFileTitle(status: status)
        case ChatSearchFilesToolRegistry.toolName:
            return searchFilesTitle(status: status)
        case ChatFileWriteToolRegistry.writeToolName:
            return fileWriteTitle(isPatch: false, status: status)
        case ChatFileWriteToolRegistry.patchToolName:
            return fileWriteTitle(isPatch: true, status: status)
        case ChatTerminalToolRegistry.toolName:
            return terminalTitle(status: status)
        default:
            return genericTitle(toolName: toolName, status: status)
        }
    }

    static func symbolName(toolName: String?, status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing:
            return "magnifyingglass"
        case .awaitingImageModelSelection:
            return "photo.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled, .declined:
            return "xmark.circle"
        case .awaitingConsent:
            return "questionmark.circle"
        case .succeeded, .running, nil:
            switch toolName {
            case ChatToolDiscoveryRegistry.toolName:
                return "magnifyingglass"
            case ChatImageToolRegistry.generateToolName,
                ChatImageToolRegistry.editToolName:
                return "photo"
            case ChatSystemMonitorToolRegistry.toolName:
                return "cpu"
            case ChatModelLibraryToolRegistry.toolName:
                return "shippingbox"
            case ChatServerStatsToolRegistry.toolName:
                return "chart.line.uptrend.xyaxis"
            case ChatSwitchModelToolRegistry.toolName:
                return "arrow.triangle.2.circlepath"
            case ChatWebSearchToolRegistry.toolName:
                return "globe"
            case ChatWebReadToolRegistry.toolName:
                return "doc.text.magnifyingglass"
            case ChatReadFileToolRegistry.toolName:
                return "doc.text"
            case ChatSearchFilesToolRegistry.toolName:
                return "doc.text.magnifyingglass"
            case ChatFileWriteToolRegistry.writeToolName,
                ChatFileWriteToolRegistry.patchToolName:
                return "square.and.pencil"
            case ChatTerminalToolRegistry.toolName:
                return "terminal"
            default:
                return "wrench.and.screwdriver"
            }
        }
    }

    private static func toolDiscoveryTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Finding available tools…"
        case .succeeded:
            return "Found available tools"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Tool search"
        case nil:
            return "Tool search"
        }
    }

    private static func imageTitle(isEdit: Bool, status: ChatTranscriptMessage.ToolStatus?)
        -> String
    {
        switch status {
        case .preparing:
            return "Checking image model…"
        case .awaitingImageModelSelection:
            return "Choose image model"
        case .running:
            return isEdit ? "Editing image…" : "Generating image…"
        case .succeeded:
            return isEdit ? "Edited image" : "Generated image"
        case .failed, .cancelled, .awaitingConsent, .declined:
            return isEdit ? "Image edit" : "Image generation"
        case nil:
            return "Image tool"
        }
    }

    private static func systemMonitorTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Checking system stats…"
        case .succeeded:
            return "Checked system stats"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "System stats"
        case nil:
            return "System tool"
        }
    }

    private static func modelLibraryTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Listing downloaded models…"
        case .succeeded:
            return "Listed downloaded models"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Model library"
        case nil:
            return "Model library tool"
        }
    }

    private static func serverStatsTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Checking server stats…"
        case .succeeded:
            return "Checked server stats"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Server stats"
        case nil:
            return "Server stats tool"
        }
    }

    private static func switchModelTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .awaitingConsent:
            return "Switch model?"
        case .awaitingImageModelSelection:
            return "Model switch"
        case .preparing, .running:
            return "Switching model…"
        case .succeeded:
            return "Switched model"
        case .declined:
            return "Model switch declined"
        case .failed, .cancelled:
            return "Model switch"
        case nil:
            return "Model switch tool"
        }
    }

    private static func webSearchTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Searching the web…"
        case .succeeded:
            return "Searched the web"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Web search"
        case nil:
            return "Web search"
        }
    }

    private static func webReadTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Reading web pages…"
        case .succeeded:
            return "Read web pages"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "Web read"
        case nil:
            return "Web read"
        }
    }

    private static func readFileTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Reading file…"
        case .succeeded:
            return "Read file"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "File read"
        case nil:
            return "File read"
        }
    }

    private static func searchFilesTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .preparing, .running:
            return "Searching files…"
        case .succeeded:
            return "Searched files"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined:
            return "File search"
        case nil:
            return "File search"
        }
    }

    private static func fileWriteTitle(
        isPatch: Bool,
        status: ChatTranscriptMessage.ToolStatus?
    ) -> String {
        switch status {
        case .awaitingConsent:
            return isPatch ? "Patch protected file?" : "Write protected file?"
        case .preparing, .running:
            return isPatch ? "Patching files…" : "Writing file…"
        case .succeeded:
            return isPatch ? "Patched files" : "Wrote file"
        case .declined:
            return isPatch ? "Patch declined" : "File write declined"
        case .failed, .cancelled, .awaitingImageModelSelection:
            return isPatch ? "File patch" : "File write"
        case nil:
            return isPatch ? "File patch" : "File write"
        }
    }

    private static func terminalTitle(status: ChatTranscriptMessage.ToolStatus?) -> String {
        switch status {
        case .awaitingConsent:
            return "Run terminal command?"
        case .preparing, .running:
            return "Running terminal command…"
        case .succeeded:
            return "Ran terminal command"
        case .declined:
            return "Terminal command declined"
        case .failed, .cancelled, .awaitingImageModelSelection:
            return "Terminal command"
        case nil:
            return "Terminal"
        }
    }

    private static func genericTitle(toolName: String?, status: ChatTranscriptMessage.ToolStatus?)
        -> String
    {
        let name = toolName ?? "tool"
        switch status {
        case .preparing, .running:
            return "Running \(name)…"
        case .succeeded:
            return "Ran \(name)"
        case .failed, .cancelled, .awaitingConsent, .awaitingImageModelSelection, .declined, nil:
            return name
        }
    }
}
