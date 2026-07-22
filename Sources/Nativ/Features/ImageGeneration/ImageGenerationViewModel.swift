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
            return "Text"
        case .imageGeneration:
            return "Image"
        }
    }
}

@MainActor
final class ImageGenerationViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var modelID = ""
    @Published var count = 1
    @Published var width = 512
    @Published var height = 512
    @Published var steps = 4
    @Published var guidance = 1.0
    @Published var seedText = ""
    @Published private(set) var sessions: [ImageGenerationSessionSummary] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var referenceImage: ImageGenerationReferenceImage?
    @Published private(set) var results: [GeneratedImage] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var statusText: String?
    @Published private(set) var errorText: String?

    private let sessionStore = ImageGenerationSessionStore()
    private var activeTask: Task<Void, Never>?
    private var storedSessions: [ImageGenerationSession] = []
    private var currentSession: ImageGenerationSession?
    private let imageSizeMultiple = 16
    private let minImageDimension = 64
    private let maxRequestDimension = 4096
    private let maxAutoEditLongestSide = 2_048

    init() {
        storedSessions = sessionStore.loadSessions()
        if let latestSession = storedSessions.sorted(by: ImageGenerationSession.recencySort).first {
            applyCurrentSession(latestSession)
        } else {
            createSession()
        }
    }

    deinit {
        activeTask?.cancel()
    }

    func applyDefaultModel(_ selectedModelID: String?) {
        guard modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selectedModelID,
              !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        modelID = selectedModelID
        persistCurrentSession(updateTimestamp: false)
    }

    func unavailableReason(isRunning: Bool) -> String? {
        if !isRunning {
            return "Server is stopped."
        }
        if normalizedModelID == nil {
            return "Enter an image model."
        }
        if normalizedPrompt == nil {
            return "Enter a prompt."
        }
        if parsedSeed == nil {
            return "Seed must be a whole number."
        }
        if isGenerating {
            return referenceImage == nil ? "Generation in progress." : "Edit in progress."
        }
        return nil
    }

    var currentLongestSide: Int {
        max(width, height)
    }

    func applyLongestSide(_ longestSide: Int) {
        let editSize = aspectFitSize(
            for: ImageGenerationPixelSize(width: width, height: height),
            longestSide: longestSide,
            upperLimit: maxRequestDimension
        )
        width = editSize.width
        height = editSize.height
        statusText = "Size set to \(width)x\(height)."
        errorText = nil
        persistCurrentSession(updateTimestamp: false)
    }

    func createSession() {
        guard !isGenerating else {
            return
        }

        let createdAt = Date()
        let session = ImageGenerationSession(
            id: UUID(),
            title: ImageGenerationSession.timestampTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            modelKind: .imageGeneration,
            prompt: "",
            modelID: modelID,
            count: 1,
            width: 512,
            height: 512,
            steps: 4,
            guidance: 1.0,
            seedText: "",
            referenceImage: nil,
            results: []
        )

        storedSessions.append(session)
        sessionStore.saveSession(session)
        applyCurrentSession(session)
    }

    func selectSession(_ sessionID: UUID) {
        guard !isGenerating, sessionID != currentSessionID else {
            return
        }

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            applyCurrentSession(session)
            return
        }

        if let session = sessionStore.loadSession(id: sessionID) {
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

        if let nextSession = storedSessions.sorted(by: ImageGenerationSession.recencySort).first {
            applyCurrentSession(nextSession)
        } else {
            currentSession = nil
            currentSessionID = nil
            createSession()
        }
    }

    func run(using appModel: NativModel) {
        guard !isGenerating,
              appModel.isRunning,
              let requestModelID = normalizedModelID,
              let requestPrompt = normalizedPrompt,
              let requestSeed = parsedSeed
        else {
            return
        }

        let requestCount = min(max(count, 1), 10)
        let requestWidth = min(max(width, minImageDimension), maxRequestDimension)
        let requestHeight = min(max(height, minImageDimension), maxRequestDimension)
        let requestSteps = min(max(steps, 1), 1_000)
        let requestGuidance = min(max(guidance, 0), 100)
        let requestReference = referenceImage

        count = requestCount
        width = requestWidth
        height = requestHeight
        steps = requestSteps
        guidance = requestGuidance
        errorText = nil
        statusText = requestReference == nil ? "Generating image..." : "Editing image..."
        isGenerating = true
        persistCurrentSession(updateTimestamp: true)

        activeTask?.cancel()
        let client = NativImageClient(baseURL: appModel.settings.serverBaseURL)
        activeTask = Task { @MainActor [weak self, weak appModel] in
            guard let self else {
                return
            }

            do {
                let response: MLXImageResponse
                if let requestReference {
                    response = try await client.edit(MLXImageEditRequest(
                        model: requestModelID,
                        prompt: requestPrompt,
                        image: [requestReference.url.path],
                        n: requestCount,
                        width: requestWidth,
                        height: requestHeight,
                        steps: requestSteps,
                        seed: requestSeed,
                        guidance: requestGuidance
                    ))
                } else {
                    response = try await client.generate(MLXImageGenerationRequest(
                        model: requestModelID,
                        prompt: requestPrompt,
                        n: requestCount,
                        width: requestWidth,
                        height: requestHeight,
                        steps: requestSteps,
                        seed: requestSeed,
                        guidance: requestGuidance
                    ))
                }

                let decodedResults = try makeGeneratedImages(from: response)
                results = decodedResults
                statusText = "\(decodedResults.count) \(decodedResults.count == 1 ? "image" : "images") ready."
                persistCurrentSession(updateTimestamp: true)
                appModel?.refreshMetricsIfRunning(force: true)
            } catch is CancellationError {
                statusText = "Cancelled."
            } catch {
                errorText = error.localizedDescription
                statusText = nil
                appModel?.refreshMetricsIfRunning(force: true)
            }

            isGenerating = false
            activeTask = nil
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func chooseReferenceImage() {
        guard !isGenerating else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        do {
            try setReferenceImage(contentsOf: url)
        } catch {
            errorText = error.localizedDescription
        }
    }

    @discardableResult
    func loadReferenceImage(from providers: [NSItemProvider]) -> Bool {
        guard !isGenerating else {
            return false
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    if let error {
                        self.errorText = error.localizedDescription
                        return
                    }

                    guard let url = Self.fileURL(from: item) else {
                        self.errorText = ImageGenerationReferenceImageError.unsupportedDrop.localizedDescription
                        return
                    }

                    do {
                        try self.setReferenceImage(contentsOf: url)
                    } catch {
                        self.errorText = error.localizedDescription
                    }
                }
            }
            return true
        }

        guard let imageDrop = providers.compactMap({ provider -> (NSItemProvider, String)? in
            guard let typeIdentifier = Self.preferredImageTypeIdentifier(for: provider) else {
                return nil
            }
            return (provider, typeIdentifier)
        }).first else {
            return false
        }

        let provider = imageDrop.0
        let typeIdentifier = imageDrop.1
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                if let error {
                    self.errorText = error.localizedDescription
                    return
                }

                guard let data else {
                    self.errorText = ImageGenerationReferenceImageError.unsupportedDrop.localizedDescription
                    return
                }

                do {
                    try self.setReferenceImage(
                        imageData: data,
                        filename: Self.dropFilename(for: typeIdentifier)
                    )
                } catch {
                    self.errorText = error.localizedDescription
                }
            }
        }
        return true
    }

    func removeReferenceImage() {
        guard !isGenerating else {
            return
        }

        referenceImage = nil
        persistCurrentSession(updateTimestamp: true)
    }

    func clearResults() {
        guard !isGenerating else {
            return
        }

        results.removeAll()
        statusText = nil
        errorText = nil
        persistCurrentSession(updateTimestamp: true)
    }

    func save(_ result: GeneratedImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "image-\(result.seed).png"

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        do {
            try result.imageData.write(to: url, options: .atomic)
            statusText = "Saved \(url.lastPathComponent)."
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setReferenceImage(contentsOf url: URL) throws {
        let referenceImage = try ImageGenerationReferenceImage(contentsOf: url)
        self.referenceImage = referenceImage
        applyEditSize(for: referenceImage.pixelSize)
        statusText = "Reference image set. Size \(width)x\(height)."
        errorText = nil
        persistCurrentSession(updateTimestamp: true)
    }

    private func setReferenceImage(imageData: Data, filename: String) throws {
        let referenceImage = try ImageGenerationReferenceImage(
            imageData: imageData,
            filename: filename
        )
        self.referenceImage = referenceImage
        applyEditSize(for: referenceImage.pixelSize)
        statusText = "Reference image set. Size \(width)x\(height)."
        errorText = nil
        persistCurrentSession(updateTimestamp: true)
    }

    private func applyCurrentSession(_ session: ImageGenerationSession) {
        currentSession = session
        currentSessionID = session.id
        prompt = session.prompt
        modelID = session.modelID
        count = session.count
        width = session.width
        height = session.height
        steps = session.steps
        guidance = session.guidance
        seedText = session.seedText
        referenceImage = session.referenceImage
        results = session.results
        statusText = nil
        errorText = nil
        refreshSessionList()
    }

    private func persistCurrentSession(updateTimestamp: Bool) {
        guard var session = currentSession else {
            return
        }

        session.modelKind = .imageGeneration
        session.prompt = prompt
        session.modelID = modelID
        session.count = count
        session.width = width
        session.height = height
        session.steps = steps
        session.guidance = guidance
        session.seedText = seedText
        session.referenceImage = referenceImage
        session.results = results
        session.title = ImageGenerationSession.defaultTitle(
            prompt: prompt,
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
        let summaries = storedSessions.map(\.summary)
        let sortedSessions = summaries.sorted(by: ImageGenerationSessionSummary.recencySort)

        guard let currentSessionID,
              let current = sortedSessions.first(where: { $0.id == currentSessionID })
        else {
            sessions = sortedSessions
            return
        }

        sessions = [current] + sortedSessions.filter { $0.id != currentSessionID }
    }

    private func applyEditSize(for sourceSize: ImageGenerationPixelSize) {
        let editSize = aspectFitSize(
            for: sourceSize,
            longestSide: min(sourceSize.longestSide, maxAutoEditLongestSide),
            upperLimit: maxAutoEditLongestSide
        )
        width = editSize.width
        height = editSize.height
    }

    private func aspectFitSize(
        for sourceSize: ImageGenerationPixelSize,
        longestSide: Int,
        upperLimit: Int
    ) -> ImageGenerationPixelSize {
        guard sourceSize.width > 0,
              sourceSize.height > 0
        else {
            return ImageGenerationPixelSize(width: width, height: height)
        }

        let sourceAspect = Double(sourceSize.width) / Double(sourceSize.height)
        let targetLongestSide = boundedRoundedDimension(longestSide, upperLimit: upperLimit)

        if sourceSize.width >= sourceSize.height {
            return editSize(width: targetLongestSide, aspect: sourceAspect)
        }
        return editSize(height: targetLongestSide, aspect: sourceAspect)
    }

    private func editSize(
        width candidateWidth: Int,
        aspect: Double
    ) -> ImageGenerationPixelSize {
        let candidateHeight = boundedRoundedDimension(
            Int((Double(candidateWidth) / aspect).rounded(.down)),
            upperLimit: maxRequestDimension
        )
        return ImageGenerationPixelSize(width: candidateWidth, height: candidateHeight)
    }

    private func editSize(
        height candidateHeight: Int,
        aspect: Double
    ) -> ImageGenerationPixelSize {
        let candidateWidth = boundedRoundedDimension(
            Int((Double(candidateHeight) * aspect).rounded(.down)),
            upperLimit: maxRequestDimension
        )
        return ImageGenerationPixelSize(width: candidateWidth, height: candidateHeight)
    }

    private func boundedRoundedDimension(_ value: Int, upperLimit: Int) -> Int {
        max(minImageDimension, roundedDownToMultiple(min(value, upperLimit)))
    }

    private func roundedDownToMultiple(_ value: Int) -> Int {
        (value / imageSizeMultiple) * imageSizeMultiple
    }

    private var normalizedModelID: String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var normalizedPrompt: String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var parsedSeed: Int?? {
        let trimmed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .some(nil)
        }
        guard let seed = Int(trimmed) else {
            return nil
        }
        return .some(seed)
    }

    private func makeGeneratedImages(from response: MLXImageResponse) throws -> [GeneratedImage] {
        let generatedImages = response.data.compactMap { item -> GeneratedImage? in
            let imageData: Data?
            if let b64JSON = item.b64JSON {
                imageData = Data(base64Encoded: b64JSON)
            } else if let path = item.path {
                imageData = try? Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                imageData = nil
            }

            guard let imageData,
                  NSImage(data: imageData) != nil
            else {
                return nil
            }

            return GeneratedImage(
                imageData: imageData,
                mimeType: item.mimeType,
                width: item.width,
                height: item.height,
                seed: item.seed,
                path: item.path,
                revisedPrompt: item.revisedPrompt
            )
        }

        guard !generatedImages.isEmpty else {
            throw NativImageError.missingImageData
        }
        return generatedImages
    }

    private static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        if let registeredImageType = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard identifier != UTType.fileURL.identifier,
                  let type = UTType(identifier)
            else {
                return false
            }
            return type.conforms(to: .image)
        }) {
            return registeredImageType
        }

        let fallbackTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .image]
        return fallbackTypes
            .map(\.identifier)
            .first(where: provider.hasItemConformingToTypeIdentifier)
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
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

    private static func dropFilename(for typeIdentifier: String) -> String {
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        return "dropped-reference.\(fileExtension)"
    }
}

private enum ImageGenerationReferenceImageError: LocalizedError {
    case invalidImageData
    case unsupportedDrop

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "The dropped item is not a valid image."
        case .unsupportedDrop:
            return "Drop an image file or image data."
        }
    }
}

private struct ImageGenerationSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelKind: SessionModelKind
    var prompt: String
    var modelID: String
    var count: Int
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var seedText: String
    var referenceImage: ImageGenerationReferenceImage?
    var results: [GeneratedImage]

    var summary: ImageGenerationSessionSummary {
        ImageGenerationSessionSummary(
            id: id,
            title: displayTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            modelKind: modelKind,
            resultCount: results.count
        )
    }

    var displayTitle: String {
        Self.defaultTitle(prompt: prompt, createdAt: createdAt, fallback: title)
    }

    static func recencySort(_ lhs: ImageGenerationSession, _ rhs: ImageGenerationSession) -> Bool {
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
        prompt: String,
        createdAt: Date,
        fallback: String? = nil
    ) -> String {
        if let promptTitle = title(fromPrompt: prompt) {
            return promptTitle
        }

        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }

        return timestampTitle(for: createdAt)
    }

    private static func title(fromPrompt prompt: String) -> String? {
        let firstLine = prompt
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

struct ImageGenerationSessionSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let modelKind: SessionModelKind
    let resultCount: Int

    static func recencySort(_ lhs: ImageGenerationSessionSummary, _ rhs: ImageGenerationSessionSummary) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
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
            // Image persistence should not block the local server UI.
        }
    }

    func deleteSession(id: UUID) {
        try? fileManager.removeItem(at: sessionURL(for: id))
    }

    private func loadSession(from url: URL) -> ImageGenerationSession? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ImageGenerationSession.self, from: data)
        } catch {
            return nil
        }
    }

    private func sessionURL(for id: UUID) -> URL {
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

struct ImageGenerationReferenceImage: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let imageData: Data
    let pixelSize: ImageGenerationPixelSize

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case filename
        case imageData
        case pixelSize
    }

    init(id: UUID = UUID(), contentsOf url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let image = try Self.makeImage(from: data)

        self.id = id
        self.filename = url.lastPathComponent
        self.imageData = data
        self.pixelSize = try Self.pixelSize(for: image)
        self.url = try Self.writeReferenceCopy(
            originalFilename: url.lastPathComponent,
            id: id,
            imageData: data
        )
    }

    init(id: UUID = UUID(), imageData data: Data, filename: String) throws {
        let image = try Self.makeImage(from: data)

        self.id = id
        self.filename = filename.isEmpty ? "dropped-reference.png" : filename
        self.imageData = data
        self.pixelSize = try Self.pixelSize(for: image)
        self.url = try Self.writeReferenceCopy(
            originalFilename: self.filename,
            id: id,
            imageData: data
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "reference.png"
        let imageData = try container.decode(Data.self, forKey: .imageData)
        let image = try Self.makeImage(from: imageData)
        let decodedPixelSize = try container.decodeIfPresent(ImageGenerationPixelSize.self, forKey: .pixelSize)
        let decodedURL = try container.decodeIfPresent(URL.self, forKey: .url)

        self.id = id
        self.filename = filename
        self.imageData = imageData
        if let decodedPixelSize {
            self.pixelSize = decodedPixelSize
        } else {
            self.pixelSize = try Self.pixelSize(for: image)
        }

        if let decodedURL,
           FileManager.default.fileExists(atPath: decodedURL.path) {
            self.url = decodedURL
        } else {
            self.url = try Self.writeReferenceCopy(
                originalFilename: filename,
                id: id,
                imageData: imageData
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(filename, forKey: .filename)
        try container.encode(imageData, forKey: .imageData)
        try container.encode(pixelSize, forKey: .pixelSize)
    }

    var nsImage: NSImage? {
        NSImage(data: imageData)
    }

    private static func makeImage(from data: Data) throws -> NSImage {
        guard let image = NSImage(data: data) else {
            throw ImageGenerationReferenceImageError.invalidImageData
        }
        return image
    }

    private static func pixelSize(for image: NSImage) throws -> ImageGenerationPixelSize {
        if let representation = image.representations
            .filter({ $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return ImageGenerationPixelSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return ImageGenerationPixelSize(width: cgImage.width, height: cgImage.height)
        }

        throw ImageGenerationReferenceImageError.invalidImageData
    }

    private static func writeReferenceCopy(
        originalFilename: String,
        id: UUID,
        imageData: Data
    ) throws -> URL {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = caches
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("ImageGeneration", isDirectory: true)
            .appendingPathComponent("References", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileExtension = URL(fileURLWithPath: originalFilename).pathExtension.isEmpty
            ? "png"
            : URL(fileURLWithPath: originalFilename).pathExtension
        let destination = directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        try imageData.write(to: destination, options: .atomic)
        return destination
    }
}

struct ImageGenerationPixelSize: Equatable, Codable, Sendable {
    let width: Int
    let height: Int

    var area: Int {
        width * height
    }

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
}
