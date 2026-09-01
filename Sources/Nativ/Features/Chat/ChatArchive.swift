import Foundation

struct ChatArchive: Codable, Equatable {
    static let format = "nativ-chat"
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let modelRepositoryID: String
    let systemPrompt: String
    let chat: ChatArchiveConversation

    init(
        chat: ChatSession,
        modelRepositoryID: String,
        systemPrompt: String,
        exportedAt: Date = .now
    ) {
        format = Self.format
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.modelRepositoryID = modelRepositoryID
        self.systemPrompt = systemPrompt
        self.chat = ChatArchiveConversation(chat)
    }
}

struct ChatArchiveConversation: Codable, Equatable {
    let title: String
    let customTitle: String?
    let createdAt: Date
    let updatedAt: Date
    let messages: [ChatTranscriptMessage]
    let imageGenerationModelID: String?

    init(_ chat: ChatSession) {
        title = chat.title
        customTitle = chat.customTitle
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        messages = chat.messages
        imageGenerationModelID = chat.imageGenerationModelID
    }
}

enum ChatArchiveError: Error, Equatable, LocalizedError {
    case invalidFormat
    case unsupportedVersion(Int)
    case missingModelRepositoryID
    case invalidAttachment(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This is not a Nativ chat export."
        case let .unsupportedVersion(version):
            "This chat export uses unsupported version \(version)."
        case .missingModelRepositoryID:
            "The chat export does not identify its model."
        case let .invalidAttachment(filename):
            "The attachment “\(filename)” contains invalid data."
        }
    }
}

enum ChatContinuationAvailability: Equatable {
    case ready(requiresModelSwitch: Bool)
    case modelMissing
    case contextExceeded(tokenCount: Int, contextWindow: Int)
}

enum ChatArchiveCodec {
    static func encode(_ archive: ChatArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> ChatArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ChatArchive.self, from: data)
        try validate(archive)
        return archive
    }

    static func importedSession(from archive: ChatArchive, now: Date = .now) throws -> ChatSession {
        try validate(archive)

        let messages = archive.chat.messages.map { message in
            ChatTranscriptMessage(
                role: message.role,
                content: message.content,
                reasoningContent: message.reasoningContent,
                modelID: message.modelID,
                createdAt: message.createdAt,
                isThinkingEnabled: message.isThinkingEnabled,
                thinkingDuration: message.thinkingDuration,
                imageAttachments: message.imageAttachments.map {
                    ChatImageAttachment(
                        filename: $0.filename,
                        mimeType: $0.mimeType,
                        base64Data: $0.base64Data
                    )
                },
                responseMetrics: message.responseMetrics,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                toolName: message.toolName,
                toolStatus: historicalStatus(message.toolStatus),
                toolArguments: message.toolArguments
            )
        }

        return ChatSession(
            id: UUID(),
            title: archive.chat.title,
            customTitle: archive.chat.customTitle,
            createdAt: archive.chat.createdAt,
            updatedAt: now,
            messages: messages,
            imageGenerationModelID: archive.chat.imageGenerationModelID,
            importedModelRepositoryID: archive.modelRepositoryID,
            importedSystemPrompt: archive.systemPrompt
        )
    }

    static func continuationAvailability(
        for archive: ChatArchive,
        installedModels: [LocalModel],
        currentModelID: String?,
        promptTokenCount: Int? = nil
    ) -> ChatContinuationAvailability {
        guard let model = installedModels.first(where: {
            $0.repoID == archive.modelRepositoryID
        }) else {
            return .modelMissing
        }

        if let promptTokenCount,
           let contextWindow = model.contextSize,
           promptTokenCount > contextWindow {
            return .contextExceeded(
                tokenCount: promptTokenCount,
                contextWindow: contextWindow
            )
        }

        return .ready(requiresModelSwitch: currentModelID != archive.modelRepositoryID)
    }

    static func promptTokenCount(in archive: ChatArchive) -> Int? {
        archive.chat.messages.reversed().compactMap { message -> Int? in
            guard message.role == .assistant else {
                return nil
            }
            return message.responseMetrics?.totalTokens
        }.first
    }

    private static func validate(_ archive: ChatArchive) throws {
        guard archive.format == ChatArchive.format else {
            throw ChatArchiveError.invalidFormat
        }
        guard archive.version == ChatArchive.currentVersion else {
            throw ChatArchiveError.unsupportedVersion(archive.version)
        }
        guard !archive.modelRepositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatArchiveError.missingModelRepositoryID
        }

        for attachment in archive.chat.messages.flatMap(\.imageAttachments) {
            guard Data(base64Encoded: attachment.base64Data) != nil else {
                throw ChatArchiveError.invalidAttachment(attachment.filename)
            }
        }
    }

    private static func historicalStatus(
        _ status: ChatTranscriptMessage.ToolStatus?
    ) -> ChatTranscriptMessage.ToolStatus? {
        switch status {
        case .preparing, .awaitingImageModelSelection, .running, .awaitingConsent:
            .cancelled
        default:
            status
        }
    }
}
