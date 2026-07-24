import AppKit
import Combine
import Foundation
import NativServerKit
import UniformTypeIdentifiers

enum ImageGenerationSizeOptions {
    static let longestSides = [512, 768, 1_024, 1_536, 2_048]
}

enum SessionModelKind: String, Codable, Equatable, Sendable {
    case language
    case imageGeneration

    var badgeTitle: String {
        switch self {
        case .language:
            "Text"
        case .imageGeneration:
            "Image"
        }
    }
}

struct ImageRequestSettings: Equatable, Codable, Sendable {
    var count = 1
    var width = 512
    var height = 512
    var steps = 4
    var guidance = 1.0
    var seedText = ""
}

struct ImageGenerationExecutor {
    func run(
        baseURL: URL,
        modelID: String,
        prompt: String,
        references: [ChatImageAttachment],
        settings: ImageRequestSettings,
        seed: Int?
    ) async throws -> [GeneratedImage] {
        let client = NativImageClient(baseURL: baseURL)
        let response: MLXImageResponse
        if references.isEmpty {
            response = try await client.generate(MLXImageGenerationRequest(
                model: modelID,
                prompt: prompt,
                n: settings.count,
                width: settings.width,
                height: settings.height,
                steps: settings.steps,
                seed: seed,
                guidance: settings.guidance
            ))
        } else {
            let paths = try references.map(Self.materializeReference).map(\.path)
            response = try await client.edit(MLXImageEditRequest(
                model: modelID,
                prompt: prompt,
                image: paths,
                n: settings.count,
                width: settings.width,
                height: settings.height,
                steps: settings.steps,
                seed: seed,
                guidance: settings.guidance
            ))
        }

        try Task.checkCancellation()
        return try Self.makeGeneratedImages(from: response)
    }

    private static func materializeReference(_ attachment: ChatImageAttachment) throws -> URL {
        guard let data = attachment.imageData else {
            throw NativImageError.missingImageData
        }
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = caches
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("ImageGeneration", isDirectory: true)
            .appendingPathComponent("References", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileExtension = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension
            ?? URL(fileURLWithPath: attachment.filename).pathExtension.nonEmpty
            ?? "png"
        let url = directory.appendingPathComponent("\(attachment.id.uuidString).\(fileExtension)")
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    private static func makeGeneratedImages(from response: MLXImageResponse) throws -> [GeneratedImage] {
        let images = response.data.compactMap { item -> GeneratedImage? in
            let data: Data?
            if let base64 = item.b64JSON {
                data = Data(base64Encoded: base64)
            } else if let path = item.path {
                data = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                data = nil
            }
            guard let data, NSImage(data: data) != nil else {
                return nil
            }
            return GeneratedImage(
                imageData: data,
                mimeType: item.mimeType,
                width: item.width,
                height: item.height,
                seed: item.seed,
                path: item.path,
                revisedPrompt: item.revisedPrompt
            )
        }
        guard !images.isEmpty else {
            throw NativImageError.missingImageData
        }
        return images
    }
}

enum ImageGenerationTurnStatus: String, Equatable, Codable, Sendable {
    case inProgress
    case completed
    case failed
    case cancelled
}

struct ImageGenerationTurn: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let prompt: String
    let referenceImages: [ChatImageAttachment]
    let modelID: String
    let settings: ImageRequestSettings
    let createdAt: Date
    var outputs: [GeneratedImage]
    var status: ImageGenerationTurnStatus
    var errorMessage: String?

    var isEdit: Bool {
        !referenceImages.isEmpty
    }
}

@MainActor
final class ImageGenerationViewModel: ObservableObject {
    static let fallbackModelID = "black-forest-labs/FLUX.2-klein-9B-kv"

    @Published var prompt = ""
    @Published var modelID = fallbackModelID
    @Published var requestSettings = ImageRequestSettings()
    @Published private(set) var sessions: [ImageGenerationSessionSummary] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var turns: [ImageGenerationTurn] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = []
    @Published private(set) var activeReference: ChatImageAttachment?
    @Published private(set) var isGenerating = false
    @Published private(set) var statusText: String?
    @Published private(set) var scrollToken = 0

    private let sessionStore = ImageGenerationSessionStore()
    private var activeTask: Task<Void, Never>?
    private var activeTurnID: UUID?
    private var storedSessions: [ImageGenerationSession] = []
    private var currentSession: ImageGenerationSession?

    private let imageSizeMultiple = 16
    private let minImageDimension = 64
    private let maxRequestDimension = 4_096
    private let maxAutoEditLongestSide = 2_048

    init() {
        storedSessions = sessionStore.loadSessions().map { session in
            var repaired = session
            for index in repaired.turns.indices where repaired.turns[index].status == .inProgress {
                repaired.turns[index].status = .failed
                repaired.turns[index].errorMessage = "Image generation was interrupted."
            }
            return repaired
        }

        if let latestSession = storedSessions.sorted(by: ImageGenerationSession.recencySort).first {
            applyCurrentSession(latestSession)
        } else {
            createSession()
        }
    }

    deinit {
        activeTask?.cancel()
    }

    var canPasteImage: Bool {
        ChatImageAttachment.canReadImages(from: .general)
    }

    var currentLongestSide: Int {
        max(requestSettings.width, requestSettings.height)
    }

    var effectiveReferenceImages: [ChatImageAttachment] {
        if !pendingImageAttachments.isEmpty {
            return pendingImageAttachments
        }
        return activeReference.map { [$0] } ?? []
    }

    var nextRequestIsEdit: Bool {
        !effectiveReferenceImages.isEmpty
    }

    func applyDefaultModel(_ selectedModelID: String?) {
        guard let selectedModelID = normalized(selectedModelID) else {
            return
        }
        modelID = selectedModelID
        persistCurrentSession(updateTimestamp: false)
    }

    func canSubmit(isRunning: Bool) -> Bool {
        isRunning
            && !isGenerating
            && normalized(modelID) != nil
            && normalized(prompt) != nil
            && parsedSeed != nil
    }

    func unavailableReason(isRunning: Bool) -> String? {
        if !isRunning {
            return "Server is stopped."
        }
        if normalized(modelID) == nil {
            return "No image model is configured."
        }
        if parsedSeed == nil {
            return "Seed must be a whole number."
        }
        if normalized(prompt) == nil {
            return nextRequestIsEdit ? "Describe how to edit the image." : "Describe an image to generate."
        }
        return nil
    }

    func applyLongestSide(_ longestSide: Int) {
        let size = aspectFitSize(
            for: ImageGenerationPixelSize(
                width: requestSettings.width,
                height: requestSettings.height
            ),
            longestSide: longestSide,
            upperLimit: maxRequestDimension
        )
        requestSettings.width = size.width
        requestSettings.height = size.height
        persistCurrentSession(updateTimestamp: false)
    }

    func createSession() {
        guard !isGenerating else {
            return
        }

        if let currentSession,
           currentSession.turns.isEmpty,
           normalized(prompt) == nil,
           pendingImageAttachments.isEmpty,
           activeReference == nil {
            applyCurrentSession(currentSession)
            return
        }

        persistCurrentSession(updateTimestamp: false)
        let createdAt = Date()
        let session = ImageGenerationSession(
            id: UUID(),
            title: ImageGenerationSession.timestampTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            modelKind: .imageGeneration,
            modelID: normalized(modelID) ?? Self.fallbackModelID,
            draftSettings: requestSettings,
            activeReference: nil,
            turns: []
        )

        storedSessions.append(session)
        sessionStore.saveSession(session)
        prompt = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func selectSession(_ sessionID: UUID) {
        guard !isGenerating, sessionID != currentSessionID else {
            return
        }

        persistCurrentSession(updateTimestamp: false)
        prompt = ""
        pendingImageAttachments.removeAll()

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            applyCurrentSession(session)
        } else if let session = sessionStore.loadSession(id: sessionID) {
            storedSessions.append(session)
            applyCurrentSession(session)
        }
    }

    func deleteSession(_ sessionID: UUID) {
        guard !isGenerating else {
            return
        }

        storedSessions.removeAll { $0.id == sessionID }
        sessionStore.deleteSession(id: sessionID)

        guard sessionID == currentSessionID else {
            refreshSessionList()
            return
        }

        prompt = ""
        pendingImageAttachments.removeAll()
        if let nextSession = storedSessions.sorted(by: ImageGenerationSession.recencySort).first {
            applyCurrentSession(nextSession)
        } else {
            currentSession = nil
            currentSessionID = nil
            turns = []
            activeReference = nil
            refreshSessionList()
        }
    }

    func sessionDataFileURL(for sessionID: UUID) -> URL? {
        guard storedSessions.contains(where: { $0.id == sessionID }) else {
            return nil
        }
        if sessionID == currentSessionID {
            persistCurrentSession(updateTimestamp: false)
        }
        let url = sessionStore.sessionURL(for: sessionID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func run(using appModel: NativModel) {
        guard !isGenerating,
              appModel.isRunning,
              let requestModelID = normalized(modelID),
              let requestPrompt = normalized(prompt),
              let requestSeed = parsedSeed,
              currentSession != nil
        else {
            return
        }

        var settings = requestSettings
        settings.count = min(max(settings.count, 1), 10)
        settings.width = boundedRoundedDimension(settings.width, upperLimit: maxRequestDimension)
        settings.height = boundedRoundedDimension(settings.height, upperLimit: maxRequestDimension)
        settings.steps = min(max(settings.steps, 1), 1_000)
        settings.guidance = min(max(settings.guidance, 0), 100)
        requestSettings = settings

        let references = effectiveReferenceImages
        if references.count == 1 {
            activeReference = references[0]
        } else if references.count > 1 {
            activeReference = nil
        }

        let turn = ImageGenerationTurn(
            id: UUID(),
            prompt: requestPrompt,
            referenceImages: references,
            modelID: requestModelID,
            settings: settings,
            createdAt: Date(),
            outputs: [],
            status: .inProgress,
            errorMessage: nil
        )

        turns.append(turn)
        activeTurnID = turn.id
        prompt = ""
        pendingImageAttachments.removeAll()
        isGenerating = true
        statusText = references.isEmpty ? "Generating image…" : "Editing image…"
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()

        activeTask?.cancel()
        let serverBaseURL = appModel.settings.serverBaseURL
        activeTask = Task { @MainActor [weak self, weak appModel] in
            guard let self else {
                return
            }

            do {
                let outputs = try await ImageGenerationExecutor().run(
                    baseURL: serverBaseURL,
                    modelID: requestModelID,
                    prompt: requestPrompt,
                    references: references,
                    settings: settings,
                    seed: requestSeed
                )
                updateTurn(turn.id) { current in
                    current.outputs = outputs
                    current.status = .completed
                }

                if outputs.count == 1 {
                    activeReference = outputs[0].attachment
                    statusText = "Image ready. Your next prompt will edit it."
                } else {
                    activeReference = nil
                    statusText = "\(outputs.count) images ready. Choose one to continue editing."
                }
                persistCurrentSession(updateTimestamp: true)
                bumpScroll()
                appModel?.refreshMetricsIfRunning(force: true)
            } catch is CancellationError {
                finishCancelledTurn(turn.id)
            } catch let error as URLError where error.code == .cancelled {
                finishCancelledTurn(turn.id)
            } catch {
                updateTurn(turn.id) { current in
                    current.status = .failed
                    current.errorMessage = error.localizedDescription
                }
                statusText = nil
                persistCurrentSession(updateTimestamp: true)
                bumpScroll()
                appModel?.refreshMetricsIfRunning(force: true)
            }

            guard activeTurnID == turn.id else {
                return
            }
            activeTurnID = nil
            isGenerating = false
            activeTask = nil
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func chooseImageAttachments() {
        guard !isGenerating else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else {
            return
        }

        appendPending(panel.urls.compactMap { try? ChatImageAttachment(contentsOf: $0) })
    }

    @discardableResult
    func attachImages(from pasteboard: NSPasteboard) -> Bool {
        guard !isGenerating else {
            return false
        }
        let attachments = ChatImageAttachment.imageAttachments(from: pasteboard)
        guard !attachments.isEmpty else {
            return false
        }
        appendPending(attachments)
        return true
    }

    func pasteImageFromClipboard() {
        attachImages(from: .general)
    }

    func captureScreenshot() {
        guard !isGenerating else {
            return
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nativ-Image-Reference-\(UUID().uuidString).png")

        Task { [weak self] in
            let captured = await ChatScreenCapture.captureInteractive(to: fileURL)
            guard captured, let attachment = try? ChatImageAttachment(contentsOf: fileURL) else {
                return
            }
            self?.appendPending([attachment])
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @discardableResult
    func loadImageAttachments(from providers: [NSItemProvider]) -> Bool {
        guard !isGenerating else {
            return false
        }

        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                    guard let url = Self.fileURL(from: item),
                          let attachment = try? ChatImageAttachment(contentsOf: url)
                    else {
                        return
                    }
                    Task { @MainActor in
                        self?.appendPending([attachment])
                    }
                }
                continue
            }

            guard let typeIdentifier = Self.preferredImageTypeIdentifier(for: provider) else {
                continue
            }
            accepted = true
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, _ in
                guard let data,
                      let image = NSImage(data: data),
                      let attachment = ChatImageAttachment.attachment(
                        from: image,
                        filename: Self.dropFilename(for: typeIdentifier)
                      )
                else {
                    return
                }
                Task { @MainActor in
                    self?.appendPending([attachment])
                }
            }
        }
        return accepted
    }

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    func clearActiveReference() {
        guard !isGenerating else {
            return
        }
        activeReference = nil
        statusText = "Your next prompt will create a new image."
        persistCurrentSession(updateTimestamp: true)
    }

    func useAsReference(_ result: GeneratedImage) {
        guard !isGenerating else {
            return
        }
        setActiveReference(result.attachment)
    }

    func useAsReference(_ attachment: ChatImageAttachment) {
        guard !isGenerating else {
            return
        }
        setActiveReference(attachment)
    }

    func save(_ result: GeneratedImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [result.imageType]
        panel.nameFieldStringValue = result.filename
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try result.imageData.write(to: url, options: .atomic)
            statusText = "Saved \(url.lastPathComponent)."
        } catch {
            statusText = "Could not save image: \(error.localizedDescription)"
        }
    }

    func persistDraftState() {
        persistCurrentSession(updateTimestamp: false)
    }

    private func appendPending(_ attachments: [ChatImageAttachment]) {
        guard !attachments.isEmpty else {
            return
        }
        pendingImageAttachments.append(contentsOf: attachments)
        if let first = attachments.first, let size = pixelSize(for: first) {
            applyEditSize(for: size)
        }
        statusText = attachments.count == 1
            ? "Reference image attached."
            : "\(attachments.count) reference images attached."
    }

    private func setActiveReference(_ attachment: ChatImageAttachment) {
        activeReference = attachment
        pendingImageAttachments.removeAll()
        if let size = pixelSize(for: attachment) {
            applyEditSize(for: size)
        }
        statusText = "Selected \(attachment.filename) for the next edit."
        persistCurrentSession(updateTimestamp: true)
    }

    private func pixelSize(for attachment: ChatImageAttachment) -> ImageGenerationPixelSize? {
        guard let data = attachment.imageData,
              let image = NSImage(data: data)
        else {
            return nil
        }
        if let representation = image.representations
            .filter({ $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return ImageGenerationPixelSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return ImageGenerationPixelSize(width: cgImage.width, height: cgImage.height)
        }
        return nil
    }

    private func finishCancelledTurn(_ turnID: UUID) {
        updateTurn(turnID) { turn in
            turn.status = .cancelled
            turn.errorMessage = "Image generation cancelled."
        }
        statusText = "Cancelled."
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func updateTurn(_ id: UUID, mutate: (inout ImageGenerationTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&turns[index])
    }

    private func applyCurrentSession(_ session: ImageGenerationSession) {
        currentSession = session
        currentSessionID = session.id
        modelID = normalized(session.modelID) ?? Self.fallbackModelID
        requestSettings = session.draftSettings
        turns = session.turns
        activeReference = session.activeReference
        statusText = nil
        refreshSessionList()
        bumpScroll()
    }

    private func persistCurrentSession(updateTimestamp: Bool) {
        guard var session = currentSession else {
            return
        }
        session.modelKind = .imageGeneration
        session.modelID = normalized(modelID) ?? Self.fallbackModelID
        session.draftSettings = requestSettings
        session.activeReference = activeReference
        session.turns = turns
        session.title = ImageGenerationSession.defaultTitle(
            turns: turns,
            createdAt: session.createdAt,
            fallback: session.title
        )
        if updateTimestamp {
            session.updatedAt = Date()
        }

        currentSession = session
        upsertStoredSession(session)
        sessionStore.saveSession(session)
        refreshSessionList()
    }

    private func upsertStoredSession(_ session: ImageGenerationSession) {
        if let index = storedSessions.firstIndex(where: { $0.id == session.id }) {
            storedSessions[index] = session
        } else {
            storedSessions.append(session)
        }
    }

    private func refreshSessionList() {
        sessions = storedSessions
            .map(\.summary)
            .sorted(by: ImageGenerationSessionSummary.recencySort)
    }

    private func bumpScroll() {
        scrollToken += 1
    }

    private func applyEditSize(for sourceSize: ImageGenerationPixelSize) {
        let size = aspectFitSize(
            for: sourceSize,
            longestSide: min(sourceSize.longestSide, maxAutoEditLongestSide),
            upperLimit: maxAutoEditLongestSide
        )
        requestSettings.width = size.width
        requestSettings.height = size.height
    }

    private func aspectFitSize(
        for sourceSize: ImageGenerationPixelSize,
        longestSide: Int,
        upperLimit: Int
    ) -> ImageGenerationPixelSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return ImageGenerationPixelSize(
                width: requestSettings.width,
                height: requestSettings.height
            )
        }

        let sourceAspect = Double(sourceSize.width) / Double(sourceSize.height)
        let targetLongestSide = boundedRoundedDimension(longestSide, upperLimit: upperLimit)
        if sourceSize.width >= sourceSize.height {
            let height = boundedRoundedDimension(
                Int((Double(targetLongestSide) / sourceAspect).rounded(.down)),
                upperLimit: upperLimit
            )
            return ImageGenerationPixelSize(width: targetLongestSide, height: height)
        }
        let width = boundedRoundedDimension(
            Int((Double(targetLongestSide) * sourceAspect).rounded(.down)),
            upperLimit: upperLimit
        )
        return ImageGenerationPixelSize(width: width, height: targetLongestSide)
    }

    private func boundedRoundedDimension(_ value: Int, upperLimit: Int) -> Int {
        max(minImageDimension, (min(value, upperLimit) / imageSizeMultiple) * imageSizeMultiple)
    }

    private var parsedSeed: Int?? {
        let trimmed = requestSettings.seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .some(nil)
        }
        return Int(trimmed).map(Optional.some)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        let fallbackTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .image]
        return provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }) ?? fallbackTypes.map(\.identifier).first(where: provider.hasItemConformingToTypeIdentifier)
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        return nil
    }

    private nonisolated static func dropFilename(for typeIdentifier: String) -> String {
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        return "dropped-reference.\(fileExtension)"
    }
}

private struct ImageGenerationSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelKind: SessionModelKind
    var modelID: String
    var draftSettings: ImageRequestSettings
    var activeReference: ChatImageAttachment?
    var turns: [ImageGenerationTurn]

    var summary: ImageGenerationSessionSummary {
        ImageGenerationSessionSummary(
            id: id,
            title: displayTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            modelKind: modelKind,
            resultCount: turns.reduce(0) { $0 + $1.outputs.count }
        )
    }

    var displayTitle: String {
        Self.defaultTitle(turns: turns, createdAt: createdAt, fallback: title)
    }

    static func recencySort(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.createdAt > rhs.createdAt : lhs.updatedAt > rhs.updatedAt
    }

    static func timestampTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func defaultTitle(
        turns: [ImageGenerationTurn],
        createdAt: Date,
        fallback: String? = nil
    ) -> String {
        if let firstPrompt = turns.first?.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstPrompt.isEmpty {
            return firstPrompt.count > 56 ? "\(firstPrompt.prefix(53))…" : firstPrompt
        }
        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedFallback.isEmpty ? timestampTitle(for: createdAt) : trimmedFallback
    }
}

struct ImageGenerationSessionSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let modelKind: SessionModelKind
    let resultCount: Int

    static func recencySort(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.createdAt > rhs.createdAt : lhs.updatedAt > rhs.updatedAt
    }
}

private struct ImageGenerationSessionStore {
    private let fileManager = FileManager.default

    func loadSessions() -> [ImageGenerationSession] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(loadSession)
            .sorted(by: ImageGenerationSession.recencySort)
    }

    func loadSession(id: UUID) -> ImageGenerationSession? {
        loadSession(from: sessionURL(for: id))
    }

    func saveSession(_ session: ImageGenerationSession) {
        do {
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: sessionURL(for: session.id), options: .atomic)
        } catch {
            // Persistence should never prevent local image generation.
        }
    }

    func deleteSession(id: UUID) {
        try? fileManager.removeItem(at: sessionURL(for: id))
    }

    private func loadSession(from url: URL) -> ImageGenerationSession? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImageGenerationSession.self, from: data)
    }

    func sessionURL(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private var sessionsDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("ImageGeneration", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}

struct ImageGenerationPixelSize: Equatable, Codable, Sendable {
    let width: Int
    let height: Int

    var longestSide: Int {
        max(width, height)
    }
}

struct GeneratedImage: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let imageData: Data
    let mimeType: String
    let width: Int
    let height: Int
    let seed: Int
    let path: String?
    let revisedPrompt: String?

    init(
        id: UUID = UUID(),
        imageData: Data,
        mimeType: String,
        width: Int,
        height: Int,
        seed: Int,
        path: String?,
        revisedPrompt: String?
    ) {
        self.id = id
        self.imageData = imageData
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.seed = seed
        self.path = path
        self.revisedPrompt = revisedPrompt
    }

    var nsImage: NSImage? {
        NSImage(data: imageData)
    }

    var imageType: UTType {
        UTType(mimeType: mimeType) ?? .png
    }

    var filename: String {
        "image-\(seed).\(imageType.preferredFilenameExtension ?? "png")"
    }

    var attachment: ChatImageAttachment {
        ChatImageAttachment(
            id: id,
            filename: filename,
            mimeType: mimeType,
            base64Data: imageData.base64EncodedString()
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
