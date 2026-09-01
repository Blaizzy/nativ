import AppKit
import Foundation
import NativServerKit
import OSLog
import UniformTypeIdentifiers

struct ChatPersistenceFailure: Equatable, Sendable {
    let operation: String
    let sessionID: UUID?
    let message: String
}

struct ChatSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var customTitle: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatTranscriptMessage]
    var pinned: Bool?
    var pinnedOrder: Int?
    var sessionOrder: Int?
    var folderID: UUID?
    var imageGenerationModelID: String?
    var scheduledTaskID: String?
    var importedModelRepositoryID: String? = nil
    var importedSystemPrompt: String? = nil

    var summary: ChatSessionSummary {
        ChatSessionSummary(
            id: id,
            title: displayTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            isPinned: pinned ?? false,
            pinnedOrder: pinnedOrder,
            sessionOrder: sessionOrder,
            folderID: folderID,
            scheduledTaskID: scheduledTaskID
        )
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        if scheduledTaskID != nil, !title.isEmpty {
            return title
        }
        return Self.defaultTitle(for: messages, createdAt: createdAt, fallback: title)
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
                return "\(firstUserMessage.imageAttachments.count) attachments"
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

        let keep = max(1, maxLength - 1)
        return "\(value.prefix(keep))…"
    }
}

struct ChatSessionSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let isPinned: Bool
    let pinnedOrder: Int?
    let sessionOrder: Int?
    let folderID: UUID?
    let scheduledTaskID: String?

    static func recencySort(_ lhs: ChatSessionSummary, _ rhs: ChatSessionSummary) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

struct ChatFolder: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    var isPinned: Bool

    init(id: UUID = UUID(), name: String, isCollapsed: Bool = false, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isCollapsed, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

struct ChatTranscriptMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user
        case assistant
        case tool
        case error
    }

    enum ToolStatus: String, Equatable, Codable {
        case preparing
        case awaitingImageModelSelection
        case running
        case succeeded
        case failed
        case cancelled
        case awaitingConsent
        case declined
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
    var toolCalls: [MLXChatToolCall]
    var toolCallID: String?
    var toolName: String?
    var toolStatus: ToolStatus?
    var toolArguments: String?

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
        responseMetrics: ChatResponseMetrics? = nil,
        toolCalls: [MLXChatToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolStatus: ToolStatus? = nil,
        toolArguments: String? = nil
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
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.toolArguments = toolArguments
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
        case toolCalls
        case toolCallID
        case toolName
        case toolStatus
        case toolArguments
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
        toolCalls = try container.decodeIfPresent([MLXChatToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolStatus = try container.decodeIfPresent(ToolStatus.self, forKey: .toolStatus)
        toolArguments = try container.decodeIfPresent(String.self, forKey: .toolArguments)

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
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolStatus, forKey: .toolStatus)
        try container.encodeIfPresent(toolArguments, forKey: .toolArguments)
    }

    var apiMessage: MLXChatMessage? {
        apiMessage(documentContext: nil)
    }

    func apiMessage(
        documentContext: String?,
        includesImages: Bool = true
    ) -> MLXChatMessage? {
        switch role {
        case .user:
            let requestContent = [content, documentContext ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let imageParts = includesImages
                ? imageAttachments.filter { $0.chatAttachmentKind == .image }
                : []
            if !imageParts.isEmpty {
                var parts: [MLXChatContentPart] = []
                if !requestContent.isEmpty {
                    parts.append(MLXChatContentPart(text: requestContent))
                }
                parts.append(contentsOf: imageParts.map { MLXChatContentPart(imageURL: $0.dataURL) })
                return MLXChatMessage(role: "user", content: .parts(parts))
            }

            return MLXChatMessage(role: "user", content: requestContent)
        case .assistant:
            guard !content.isEmpty || !reasoningContent.isEmpty || !toolCalls.isEmpty else {
                return nil
            }
            return MLXChatMessage(
                role: "assistant",
                content: content,
                reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls
            )
        case .tool:
            guard let toolCallID else {
                return nil
            }
            return MLXChatMessage(
                role: "tool",
                content: content,
                toolCallID: toolCallID,
                name: toolName
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
    let specAcceptanceRate: Double?

    var hasVisibleValues: Bool {
        totalTokens != nil
            || generatedTokens != nil
            || decodeTokensPerSecond != nil
            || peakMemoryGB != nil
            || specAcceptanceRate != nil
    }

    init(
        totalTokens: Int? = nil,
        generatedTokens: Int? = nil,
        decodeTokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil,
        specAcceptanceRate: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.generatedTokens = generatedTokens
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
        self.specAcceptanceRate = specAcceptanceRate
    }

    init(completion: MLXChatCompletion) {
        self.init(
            totalTokens: completion.usage?.resolvedTotalTokens,
            generatedTokens: completion.usage?.completionTokens,
            decodeTokensPerSecond: completion.resolvedDecodeTokensPerSecond,
            peakMemoryGB: completion.usage?.peakMemoryGB,
            specAcceptanceRate: completion.usage?.specAcceptanceRate
        )
    }
}

struct MediaAssetReference: Equatable, Codable, Hashable, Sendable {
    let relativePath: String
    let byteCount: Int
}

/// Durable, app-owned media storage. Session JSON owns references; binary payloads live in
/// Application Support so session-list loading never has to decode them.
final class MediaAssetStore: @unchecked Sendable {
    static let shared = MediaAssetStore()

    private static let manifestLock = NSLock()
    private let fileManager: FileManager
    let rootDirectory: URL

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootDirectory = support
                .appendingPathComponent("Nativ", isDirectory: true)
                .appendingPathComponent("MediaAssets", isDirectory: true)
        }
    }

    func store(
        _ data: Data,
        id: UUID = UUID(),
        mimeType: String,
        filename: String
    ) throws -> MediaAssetReference {
        let filenameExtension = URL(fileURLWithPath: filename).pathExtension
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension
            ?? (filenameExtension.isEmpty ? nil : filenameExtension)
            ?? "dat"
        let relativePath = "Objects/\(id.uuidString.prefix(2))/\(id.uuidString).\(ext)"
        let destination = try validatedURL(for: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return MediaAssetReference(
            relativePath: relativePath,
            byteCount: data.count
        )
    }

    func data(for reference: MediaAssetReference) -> Data? {
        guard let url = try? validatedURL(for: reference.relativePath) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    func fileURL(for reference: MediaAssetReference) -> URL? {
        guard let url = try? validatedURL(for: reference.relativePath),
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    func updateOwner(_ owner: String, assets: Set<MediaAssetReference>) {
        Self.manifestLock.lock()
        defer { Self.manifestLock.unlock() }
        var manifest = loadManifest()
        manifest[owner] = assets.map(\.relativePath).sorted()
        if assets.isEmpty { manifest.removeValue(forKey: owner) }
        writeManifest(manifest)
    }

    func removeOwner(_ owner: String, orphanGracePeriod: TimeInterval = 86_400) {
        Self.manifestLock.lock()
        defer { Self.manifestLock.unlock() }
        var manifest = loadManifest()
        manifest.removeValue(forKey: owner)
        writeManifest(manifest)
        pruneOrphans(ownedPaths: Set(manifest.values.joined()), gracePeriod: orphanGracePeriod)
    }

    private func validatedURL(for relativePath: String) throws -> URL {
        let relative = URL(fileURLWithPath: relativePath)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relative.pathComponents.contains("..")
        else { throw CocoaError(.fileReadInvalidFileName) }
        return rootDirectory.appendingPathComponent(relativePath)
    }

    private var manifestURL: URL { rootDirectory.appendingPathComponent("owners.json") }

    private func loadManifest() -> [String: [String]] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    private func writeManifest(_ manifest: [String: [String]]) {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            NSLog("Nativ media ownership manifest write failed: %@", error.localizedDescription)
        }
    }

    private func pruneOrphans(ownedPaths: Set<String>, gracePeriod: TimeInterval) {
        let objects = rootDirectory.appendingPathComponent("Objects", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: objects,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return }
        // temporaryDirectory commonly enters as /var while enumeration returns /private/var.
        // Resolve both sides so orphan detection cannot silently skip an entire store.
        let prefix = rootDirectory.resolvingSymlinksInPath().path + "/"
        let cutoff = Date().addingTimeInterval(-gracePeriod)
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  (gracePeriod <= 0 || (values.contentModificationDate ?? .distantPast) <= cutoff)
            else { continue }
            let resolvedPath = url.resolvingSymlinksInPath().path
            let relativePath = resolvedPath.hasPrefix(prefix)
                ? String(resolvedPath.dropFirst(prefix.count))
                : ""
            if !relativePath.isEmpty, !ownedPaths.contains(relativePath) {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

struct ChatImageAttachment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var filename: String
    var mimeType: String
    private var inlineBase64Data: String?
    private(set) var asset: MediaAssetReference?

    enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, base64Data, asset
    }

    var base64Data: String {
        get {
            if let inlineBase64Data { return inlineBase64Data }
            return imageData?.base64EncodedString() ?? ""
        }
        set {
            inlineBase64Data = newValue
            asset = nil
        }
    }

    init(id: UUID = UUID(), filename: String, mimeType: String, base64Data: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.inlineBase64Data = base64Data
        self.asset = nil
    }

    init(id: UUID, filename: String, mimeType: String, asset: MediaAssetReference) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.inlineBase64Data = nil
        self.asset = asset
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
        let id = UUID()
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let asset = try MediaAssetStore.shared.store(
            data,
            id: id,
            mimeType: mimeType,
            filename: url.lastPathComponent
        )
        self.init(id: id, filename: url.lastPathComponent, mimeType: mimeType, asset: asset)
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(base64Data)"
    }

    var imageData: Data? {
        if let asset { return MediaAssetStore.shared.data(for: asset) }
        guard let inlineBase64Data else { return nil }
        return Data(base64Encoded: inlineBase64Data)
    }

    var assetFileURL: URL? {
        asset.flatMap(MediaAssetStore.shared.fileURL)
    }

    mutating func externalize(using store: MediaAssetStore = .shared) throws -> Bool {
        guard asset == nil, let inlineBase64Data,
              let data = Data(base64Encoded: inlineBase64Data)
        else { return false }
        asset = try store.store(data, id: id, mimeType: mimeType, filename: filename)
        self.inlineBase64Data = nil
        return true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename = try container.decode(String.self, forKey: .filename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        asset = try container.decodeIfPresent(MediaAssetReference.self, forKey: .asset)
        inlineBase64Data = try container.decodeIfPresent(String.self, forKey: .base64Data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(asset, forKey: .asset)
        if asset == nil { try container.encodeIfPresent(inlineBase64Data, forKey: .base64Data) }
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
        let id = UUID()
        guard let asset = try? MediaAssetStore.shared.store(
            png,
            id: id,
            mimeType: "image/png",
            filename: filename
        ) else { return nil }
        return ChatImageAttachment(id: id, filename: filename, mimeType: "image/png", asset: asset)
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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Nativ",
        category: "ChatPersistence"
    )

    var onFailure: ((ChatPersistenceFailure) -> Void)?

    private func reportFailure(
        _ operation: String,
        sessionID: UUID? = nil,
        error: Error
    ) {
        Self.logger.error(
            "\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        onFailure?(
            ChatPersistenceFailure(
                operation: operation,
                sessionID: sessionID,
                message: error.localizedDescription
            )
        )
    }
    private let fileManager: FileManager
    private let chatDirectory: URL
    private let legacyChatDirectory: URL?
    private let mediaStore: MediaAssetStore

    init(
        chatDirectory: URL? = nil,
        legacyChatDirectory: URL? = nil,
        mediaStore: MediaAssetStore = .shared,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.mediaStore = mediaStore
        if let chatDirectory {
            self.chatDirectory = chatDirectory
            self.legacyChatDirectory = legacyChatDirectory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.chatDirectory = support
                .appendingPathComponent("Nativ", isDirectory: true)
                .appendingPathComponent("Chat", isDirectory: true)
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.legacyChatDirectory = caches
                .appendingPathComponent("Nativ", isDirectory: true)
                .appendingPathComponent("Chat", isDirectory: true)
        }
    }

    func loadSessions() -> [ChatSession] {
        migrateLegacyStoreIfNeeded()
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
        migrateLegacyStoreIfNeeded()
        return loadSession(from: sessionURL(for: id))
    }

    @discardableResult
    func saveSession(_ session: ChatSession) -> Bool {
        do {
            migrateLegacyStoreIfNeeded()
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )

            var persisted = session
            _ = try persisted.externalizeAssets(using: mediaStore)
            let data = try makeEncoder().encode(persisted)
            try data.write(to: sessionURL(for: persisted.id), options: .atomic)
            mediaStore.updateOwner("chat:\(persisted.id.uuidString)", assets: persisted.assetReferences)
            return true
        } catch {
            reportFailure("saveSession", sessionID: session.id, error: error)
            return false
        }
    }

    func deleteSession(id: UUID) {
        do {
            try fileManager.removeItem(at: sessionURL(for: id))
        } catch CocoaError.fileNoSuchFile {
            // Continue so stale ownership and index records are also removed.
        } catch {
            reportFailure("deleteSession", sessionID: id, error: error)
            return
        }
        mediaStore.removeOwner("chat:\(id.uuidString)")
    }

    func loadFolders() -> [ChatFolder] {
        guard let data = try? Data(contentsOf: foldersURL) else {
            return []
        }
        return (try? JSONDecoder().decode([ChatFolder].self, from: data)) ?? []
    }

    func saveFolders(_ folders: [ChatFolder]) {
        do {
            try fileManager.createDirectory(
                at: chatDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(folders)
            try data.write(to: foldersURL, options: .atomic)
        } catch {
            reportFailure("saveFolders", error: error)
        }
    }

    private func loadSession(from url: URL) -> ChatSession? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            var session = try makeDecoder().decode(ChatSession.self, from: data)
            if try session.externalizeAssets(using: mediaStore) {
                try makeEncoder().encode(session).write(to: url, options: .atomic)
            }
            mediaStore.updateOwner("chat:\(session.id.uuidString)", assets: session.assetReferences)
            return session
        } catch {
            NSLog("Nativ chat session load failed for %@: %@", url.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func migrateLegacyStoreIfNeeded() {
        guard let legacyChatDirectory,
              legacyChatDirectory.standardizedFileURL != chatDirectory.standardizedFileURL,
              fileManager.fileExists(atPath: legacyChatDirectory.path)
        else { return }
        do {
            try fileManager.createDirectory(at: chatDirectory, withIntermediateDirectories: true)
            for name in ["folders.json", "current.json"] {
                let source = legacyChatDirectory.appendingPathComponent(name)
                let destination = chatDirectory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: source, to: destination)
                }
            }
            let legacySessions = legacyChatDirectory.appendingPathComponent("Sessions", isDirectory: true)
            if fileManager.fileExists(atPath: legacySessions.path) {
                try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
                for source in try fileManager.contentsOfDirectory(at: legacySessions, includingPropertiesForKeys: nil)
                    where source.pathExtension == "json" {
                    let destination = sessionsDirectory.appendingPathComponent(source.lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.copyItem(at: source, to: destination)
                    }
                }
            }
        } catch {
            NSLog("Nativ legacy chat migration failed: %@", error.localizedDescription)
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

    func sessionsFingerprint() -> String {
        let urls = (try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = values?.fileSize ?? 0
                return "\(url.lastPathComponent):\(mtime):\(size)"
            }
            .sorted()
            .joined(separator: "|")
    }

    func sessionURL(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private var sessionsDirectory: URL {
        chatDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    private var foldersURL: URL {
        chatDirectory.appendingPathComponent("folders.json")
    }

    private var legacyTranscriptURL: URL {
        chatDirectory.appendingPathComponent("current.json")
    }

}

private extension ChatSession {
    var assetReferences: Set<MediaAssetReference> {
        Set(messages.flatMap(\.imageAttachments).compactMap(\.asset))
    }

    mutating func externalizeAssets(using store: MediaAssetStore) throws -> Bool {
        var changed = false
        for messageIndex in messages.indices {
            for attachmentIndex in messages[messageIndex].imageAttachments.indices {
                changed = try messages[messageIndex].imageAttachments[attachmentIndex]
                    .externalize(using: store) || changed
            }
        }
        return changed
    }
}

enum ChatSessionLoadPolicy {
    static func shouldNormalizeOnApply(sessionID: UUID, activeRequestSessionID: UUID?) -> Bool {
        sessionID != activeRequestSessionID
    }
}
