import Foundation
import NativServerKit

enum NativActionToolError: LocalizedError {
    case missingArgument(String)
    case serverNotRunning
    case fileNotFound(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "This call needs a \(name)."
        case .serverNotRunning:
            "Start Nativ's local model server first."
        case .fileNotFound(let path):
            "There is no file at \(path)."
        case .timedOut(let what):
            "\(what) did not finish in time."
        }
    }
}

struct NativActionToolProvider: NativCapabilityProvider {
    enum Action: String, CaseIterable {
        case status = "get_nativ_status"
        case runPrompt = "run_prompt"
        case generateImage = "generate_image"
        case transcribeAudio = "transcribe_audio"
        case loadModel = "load_model"
        case startServer = "start_server"
        case stopServer = "stop_server"
    }

    let model: NativModel

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        Action.allCases.map(Self.definition(for:))
    }

    func handles(_ name: String) async -> Bool {
        Action(rawValue: name) != nil
    }

    func requiresConsent(_ name: String) async -> Bool {
        false
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        guard let action = Action(rawValue: name) else {
            throw ChatImageToolError.unsupportedTool(name)
        }
        let arguments = Self.arguments(from: argumentsJSON)
        let payload: Result
        switch action {
        case .status:
            payload = await status()
        case .runPrompt:
            payload = try await runPrompt(arguments)
        case .generateImage:
            payload = try await generateImage(arguments)
        case .transcribeAudio:
            payload = try await transcribeAudio(arguments)
        case .loadModel:
            payload = try await loadModel(arguments)
        case .startServer:
            payload = try await setServer(running: true)
        case .stopServer:
            payload = try await setServer(running: false)
        }
        let data = try JSONEncoder().encode(payload)
        return ChatToolExecutionOutcome(
            content: String(decoding: data, as: UTF8.self),
            attachments: []
        )
    }

    private struct Result: Encodable {
        var ok = true
        var model: String?
        var text: String?
        var serverIsRunning: Bool?
        var paths: [String]?
        var baseURL: String?
        var imageModel: String?
        var speechModel: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case model
            case text
            case serverIsRunning = "server_is_running"
            case paths
            case baseURL = "base_url"
            case imageModel = "image_model"
            case speechModel = "speech_to_text_model"
            case error
        }
    }

    private func status() async -> Result {
        let settings = await model.settings.normalized()
        let isRunning = await model.isRunning
        let baseURL = await model.activeServerBaseURL?.absoluteString
        return Result(
            model: settings.languageModelID,
            serverIsRunning: isRunning,
            baseURL: baseURL,
            imageModel: settings.imageGenerationModelID,
            speechModel: settings.speechToTextModelID
        )
    }

    private func settingsWithServerRunning() async throws -> NativSettings {
        guard await model.isRunning else {
            throw NativActionToolError.serverNotRunning
        }
        return await model.settings.normalized()
    }

    private func runPrompt(_ arguments: [String: Any]) async throws -> Result {
        let prompt = try Self.required("prompt", in: arguments)
        let settings = try await settingsWithServerRunning()
        guard let modelID = arguments["model"] as? String ?? settings.languageModelID else {
            throw NativActionToolError.missingArgument("model")
        }

        var messages: [MLXChatMessage] = []
        if let system = arguments["system"] as? String, !system.isEmpty {
            messages.append(MLXChatMessage(role: "system", content: system))
        }
        messages.append(MLXChatMessage(role: "user", content: prompt))

        let completion = try await NativChatClient(
            baseURL: settings.serverBaseURL,
            apiKey: settings.serverAPIKey
        )
        .completeChat(
            MLXChatCompletionRequest(
                model: modelID,
                messages: messages,
                maxTokens: arguments["max_tokens"] as? Int ?? settings.maxTokens,
                temperature: settings.temperature,
                topK: settings.topK,
                topP: settings.topP,
                minP: settings.minP,
                enableThinking: false
            )
        )
        return Result(model: modelID, text: completion.content)
    }

    private func generateImage(_ arguments: [String: Any]) async throws -> Result {
        let prompt = try Self.required("prompt", in: arguments)
        let settings = try await settingsWithServerRunning()
        guard let modelID = arguments["model"] as? String ?? settings.imageGenerationModelID else {
            throw NativActionToolError.missingArgument("model")
        }

        var request = ImageRequestSettings()
        request.count = arguments["count"] as? Int ?? request.count
        request.width = arguments["width"] as? Int ?? request.width
        request.height = arguments["height"] as? Int ?? request.height

        let images = try await ImageGenerationExecutor().run(
            baseURL: settings.serverBaseURL,
            apiKey: settings.serverAPIKey,
            modelID: modelID,
            prompt: prompt,
            references: [],
            settings: request,
            seed: arguments["seed"] as? Int
        )
        return Result(model: modelID, paths: try Self.write(images))
    }

    private static func write(_ images: [GeneratedImage]) throws -> [String] {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Nativ", isDirectory: true)
        .appendingPathComponent("Plugin Images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try images.map { image in
            let url = directory
                .appendingPathComponent(image.id.uuidString)
                .appendingPathExtension(image.mimeType == "image/jpeg" ? "jpg" : "png")
            try image.imageData.write(to: url, options: .atomic)
            return url.path
        }
    }

    private func transcribeAudio(_ arguments: [String: Any]) async throws -> Result {
        let path = (try Self.required("path", in: arguments) as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw NativActionToolError.fileNotFound(path)
        }
        let transcription = try await NativTranscriptionRunner(
            configuration: await model.voiceTranscriptionConfiguration()
        )
        .transcribe(
            fileURL: URL(filePath: path),
            requestedModelID: arguments["model"] as? String
        )
        return Result(model: transcription.modelID, text: transcription.text)
    }

    private func loadModel(_ arguments: [String: Any]) async throws -> Result {
        let modelID = try Self.required("model", in: arguments)
        let settings = await model.settings.normalized()
        let installed = try await LocalModelDiscovery.scan(searchPaths: settings.localModelSearchPaths)
        guard installed.contains(where: { $0.repoID == modelID && $0.capabilities.contains(.text) })
        else {
            return Result(
                ok: false,
                model: modelID,
                error: "That model is not installed as a language model, so nothing changed."
            )
        }

        await model.switchLanguageModel(to: modelID)
        guard await Self.wait(forSeconds: 240, until: { !model.modelSwitchInProgress }) else {
            throw NativActionToolError.timedOut("Loading \(modelID)")
        }
        if let failure = await model.modelLoadFailure {
            return Result(ok: false, model: modelID, error: failure.message)
        }
        return Result(model: modelID, serverIsRunning: await model.isRunning)
    }

    private func setServer(running: Bool) async throws -> Result {
        if running {
            await model.startServer()
        } else {
            await model.stopServer()
        }
        guard await Self.wait(forSeconds: 180, until: { model.isRunning == running }) else {
            throw NativActionToolError.timedOut(running ? "Starting the server" : "Stopping the server")
        }
        return Result(serverIsRunning: running)
    }

    private static func wait(
        forSeconds seconds: Int,
        until condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<(seconds * 5) {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    private static func required(_ name: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[name] as? String, !value.isEmpty else {
            throw NativActionToolError.missingArgument(name)
        }
        return value
    }

    private static func arguments(from json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    private static func definition(for action: Action) -> MLXChatToolDefinition {
        switch action {
        case .status:
            return definition(
                action,
                "Report whether Nativ's server is running, which models are chosen, and the base URL for OpenAI-compatible requests.",
                properties: [:],
                required: []
            )
        case .runPrompt:
            return definition(
                action,
                "Send a prompt to a local language model through Nativ and return the reply.",
                properties: [
                    "prompt": string("What to send to the model."),
                    "model": string("Model to use. Defaults to the one Nativ has loaded."),
                    "system": string("Optional system instructions."),
                    "max_tokens": integer("Maximum tokens to generate."),
                ],
                required: ["prompt"]
            )
        case .generateImage:
            return definition(
                action,
                "Generate an image with a local image model and return the file paths.",
                properties: [
                    "prompt": string("What to draw."),
                    "model": string("Image model to use. Defaults to the one chosen in Nativ."),
                    "width": integer("Pixel width."),
                    "height": integer("Pixel height."),
                    "count": integer("How many images to make."),
                    "seed": integer("Seed for repeatable output."),
                ],
                required: ["prompt"]
            )
        case .transcribeAudio:
            return definition(
                action,
                "Transcribe an audio file on this Mac with a local speech-to-text model.",
                properties: [
                    "path": string("Path to the audio file."),
                    "model": string("Model to use. Defaults to the installed speech model."),
                ],
                required: ["path"]
            )
        case .loadModel:
            return definition(
                action,
                "Make Nativ load a local language model, restarting its server if needed.",
                properties: ["model": string("Model repository id to load.")],
                required: ["model"]
            )
        case .startServer:
            return definition(action, "Start Nativ's local model server.", properties: [:], required: [])
        case .stopServer:
            return definition(action, "Stop Nativ's local model server.", properties: [:], required: [])
        }
    }

    private static func definition(
        _ action: Action,
        _ description: String,
        properties: [String: MLXJSONValue],
        required: [String]
    ) -> MLXChatToolDefinition {
        MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: action.rawValue,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ])
        ))
    }

    private static func string(_ description: String) -> MLXJSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> MLXJSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
