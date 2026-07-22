import AppKit
import Foundation
import NativServerKit
import UniformTypeIdentifiers

struct ChatSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatTranscriptMessage]

    var summary: ChatSessionSummary {
        ChatSessionSummary(
            id: id,
            title: displayTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count
        )
    }

    var displayTitle: String {
        Self.defaultTitle(for: messages, createdAt: createdAt, fallback: title)
    }

    static func recencySort(_ lhs: ChatSession, _ rhs: ChatSession) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    static func timestampTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func defaultTitle(
        for messages: [ChatTranscriptMessage],
        createdAt: Date,
        fallback: String? = nil
    ) -> String {
        if let firstUserMessage = messages.first(where: { $0.role == .user }) {
            if let firstUserTitle = title(fromUserContent: firstUserMessage.content) {
                return firstUserTitle
            }

            if !firstUserMessage.imageAttachments.isEmpty {
                if firstUserMessage.imageAttachments.count == 1 {
                    return firstUserMessage.imageAttachments[0].filename
                }
                return "\(firstUserMessage.imageAttachments.count) images"
            }
        }

        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }

        return timestampTitle(for: createdAt)
    }

    private static func title(fromUserContent content: String) -> String? {
        let firstLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let firstLine else {
            return nil
        }

        return truncateTitle(firstLine)
    }

    private static func truncateTitle(_ value: String, maxLength: Int = 56) -> String {
        guard value.count > maxLength else {
            return value
        }

        let keep = max(1, maxLength - 3)
        return "\(value.prefix(keep))..."
    }
}

struct ChatSessionSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int

    static func recencySort(_ lhs: ChatSessionSummary, _ rhs: ChatSessionSummary) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

struct ChatTranscriptMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user
        case assistant
        case error
    }

    let id: UUID
    var role: Role
    var content: String
    var reasoningContent: String
    var modelID: String?
    var createdAt: Date
    var isStreaming: Bool
    var isThinkingEnabled: Bool
    var thinkingDuration: TimeInterval?
    var imageAttachments: [ChatImageAttachment]
    var responseMetrics: ChatResponseMetrics?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoningContent: String = "",
        modelID: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        isThinkingEnabled: Bool = false,
        thinkingDuration: TimeInterval? = nil,
        imageAttachments: [ChatImageAttachment] = [],
        responseMetrics: ChatResponseMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.modelID = modelID
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.isThinkingEnabled = isThinkingEnabled
        self.thinkingDuration = thinkingDuration
        self.imageAttachments = imageAttachments
        self.responseMetrics = responseMetrics
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case reasoningContent
        case modelID
        case createdAt
        case isStreaming
        case isThinkingEnabled
        case thinkingDuration
        case imageAttachments
        case responseMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isStreaming = false
        isThinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isThinkingEnabled) ?? false
        thinkingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .thinkingDuration)
        imageAttachments = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .imageAttachments) ?? []
        responseMetrics = try container.decodeIfPresent(ChatResponseMetrics.self, forKey: .responseMetrics)

        if role == .error,
           content == NativChatError.missingAssistantContent.localizedDescription,
           !reasoningContent.isEmpty {
            role = .assistant
            content = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(false, forKey: .isStreaming)
        try container.encode(isThinkingEnabled, forKey: .isThinkingEnabled)
        try container.encodeIfPresent(thinkingDuration, forKey: .thinkingDuration)
        try container.encode(imageAttachments, forKey: .imageAttachments)
        try container.encodeIfPresent(responseMetrics, forKey: .responseMetrics)
    }

    var apiMessage: MLXChatMessage? {
        switch role {
        case .user:
            if !imageAttachments.isEmpty {
                var parts: [MLXChatContentPart] = []
                if !content.isEmpty {
                    parts.append(MLXChatContentPart(text: content))
                }
                parts.append(contentsOf: imageAttachments.map { MLXChatContentPart(imageURL: $0.dataURL) })
                return MLXChatMessage(role: "user", content: .parts(parts))
            }

            return MLXChatMessage(role: "user", content: content)
        case .assistant:
            guard !content.isEmpty || !reasoningContent.isEmpty else {
                return nil
            }
            return MLXChatMessage(
                role: "assistant",
                content: content,
                reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent
            )
        case .error:
            return nil
        }
    }
}

struct ChatResponseMetrics: Equatable, Codable {
    let totalTokens: Int?
    let generatedTokens: Int?
    let decodeTokensPerSecond: Double?
    let peakMemoryGB: Double?

    var hasVisibleValues: Bool {
        totalTokens != nil
            || generatedTokens != nil
            || decodeTokensPerSecond != nil
            || peakMemoryGB != nil
    }

    init(
        totalTokens: Int? = nil,
        generatedTokens: Int? = nil,
        decodeTokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.generatedTokens = generatedTokens
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
    }

    init(completion: MLXChatCompletion) {
        self.init(
            totalTokens: completion.usage?.resolvedTotalTokens,
            generatedTokens: completion.usage?.completionTokens,
            decodeTokensPerSecond: completion.resolvedDecodeTokensPerSecond,
            peakMemoryGB: completion.usage?.peakMemoryGB
        )
    }
}

struct ChatImageAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    var filename: String
    var mimeType: String
    var base64Data: String

    init(id: UUID = UUID(), filename: String, mimeType: String, base64Data: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64Data = base64Data
    }

    init(contentsOf url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        self.init(
            filename: url.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            base64Data: data.base64EncodedString()
        )
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(base64Data)"
    }

    var imageData: Data? {
        Data(base64Encoded: base64Data)
    }

    static func canReadImages(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: isImageURL) {
            return true
        }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func imageAttachments(from pasteboard: NSPasteboard) -> [ChatImageAttachment] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let fileAttachments = urls
                .filter(isImageURL)
                .compactMap { try? ChatImageAttachment(contentsOf: $0) }
            if !fileAttachments.isEmpty {
                return fileAttachments
            }
        }

        guard let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] else {
            return []
        }
        return images.enumerated().compactMap { index, image in
            attachment(from: image, filename: pastedImageFilename(index: index))
        }
    }

    static func attachment(from image: NSImage, filename: String) -> ChatImageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }
        return ChatImageAttachment(
            filename: filename,
            mimeType: "image/png",
            base64Data: png.base64EncodedString()
        )
    }

    private static func isImageURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func pastedImageFilename(index: Int) -> String {
        index == 0 ? "Pasted Image.png" : "Pasted Image \(index + 1).png"
    }
}

struct ChatSessionStore {
    private let fileManager = FileManager.default

    init() {}

    func loadSessions() -> [ChatSession] {
        migrateLegacyTranscriptIfNeeded()

        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(loadSession)
            .sorted(by: ChatSession.recencySort)
    }

    func loadSession(id: UUID) -> ChatSession? {
        loadSession(from: sessionURL(for: id))
    }

    func saveSession(_ session: ChatSession) {
        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session)
            try data.write(to: sessionURL(for: session.id), options: .atomic)
        } catch {
            // Chat persistence should not block the local server UI.
        }
    }

    func deleteSession(id: UUID) {
        try? fileManager.removeItem(at: sessionURL(for: id))
    }

    private func loadSession(from url: URL) -> ChatSession? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatSession.self, from: data)
        } catch {
            return nil
        }
    }

    private func migrateLegacyTranscriptIfNeeded() {
        guard existingSessionURLs().isEmpty,
              let data = try? Data(contentsOf: legacyTranscriptURL)
        else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let messages = try decoder.decode([ChatTranscriptMessage].self, from: data)
            guard !messages.isEmpty else {
                try? fileManager.removeItem(at: legacyTranscriptURL)
                return
            }

            let createdAt = messages.first?.createdAt ?? Date()
            let updatedAt = messages.last?.createdAt ?? createdAt
            let session = ChatSession(
                id: UUID(),
                title: ChatSession.timestampTitle(for: createdAt),
                createdAt: createdAt,
                updatedAt: updatedAt,
                messages: messages
            )
            saveSession(session)
            try? fileManager.removeItem(at: legacyTranscriptURL)
        } catch {
            return
        }
    }

    private func existingSessionURLs() -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
        .filter { $0.pathExtension == "json" }
    }

    private func sessionURL(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private var chatDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return caches
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
    }

    private var sessionsDirectory: URL {
        chatDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    private var legacyTranscriptURL: URL {
        chatDirectory.appendingPathComponent("current.json")
    }
}
