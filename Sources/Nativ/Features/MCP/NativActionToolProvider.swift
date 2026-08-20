import Foundation
import NativServerKit

struct NativActionToolProvider: NativCapabilityProvider {
    let model: NativModel

    private var tools: [NativTool] {
        [status, runPrompt, generateImage, transcribeAudio, loadModel, startServer, stopServer]
    }

    func definitions(_ options: NativToolCatalogOptions) async -> [MLXChatToolDefinition] {
        tools.map(\.definition)
    }

    func handles(_ name: String) async -> Bool {
        tools.contains { $0.name == name }
    }

    func requiresConsent(_ name: String) async -> Bool {
        false
    }

    func call(
        _ name: String,
        argumentsJSON: String?,
        context: ChatToolExecutionContext
    ) async throws -> ChatToolExecutionOutcome {
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw ChatImageToolError.unsupportedTool(name)
        }
        let payload = try await tool.run(NativToolArguments(json: argumentsJSON))
        let data = try JSONEncoder().encode(MLXJSONValue.object(payload))
        return ChatToolExecutionOutcome(
            content: String(decoding: data, as: UTF8.self),
            attachments: []
        )
    }

    private var status: NativTool {
        NativTool(
            name: NativMCPAccess.statusToolName,
            description: "Report whether Nativ's server is running, which models are chosen, and the base URL for OpenAI-compatible requests.",
            parameters: NativTool.schema()
        ) { [model] _ in
            let settings = await model.settings.normalized()
            return await [
                "ok": .bool(true),
                "server_is_running": .bool(model.isRunning),
                "base_url": model.activeServerBaseURL.map { .string($0.absoluteString) } ?? .null,
                "model": settings.languageModelID.map { .string($0) } ?? .null,
                "image_model": settings.imageGenerationModelID.map { .string($0) } ?? .null,
                "speech_to_text_model": settings.speechToTextModelID.map { .string($0) } ?? .null,
            ]
        }
    }

    private var runPrompt: NativTool {
        NativTool(
            name: "run_prompt",
            description: "Send a prompt to a local language model through Nativ and return the reply.",
            parameters: NativTool.schema(
                properties: [
                    "prompt": NativTool.text("What to send to the model."),
                    "model": NativTool.text("Model to use. Defaults to the one Nativ has loaded."),
                    "system": NativTool.text("Optional system instructions."),
                    "max_tokens": NativTool.number("Maximum tokens to generate."),
                ],
                required: ["prompt"]
            )
        ) { [model] arguments in
            let prompt = try arguments.required("prompt")
            let settings = try await Self.runningSettings(model)
            guard let modelID = arguments.string("model") ?? settings.languageModelID else {
                throw NativToolError.missingArgument("model")
            }

            var messages: [MLXChatMessage] = []
            if let system = arguments.string("system") {
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
                    maxTokens: arguments.integer("max_tokens") ?? settings.maxTokens,
                    temperature: settings.temperature,
                    topK: settings.topK,
                    topP: settings.topP,
                    minP: settings.minP,
                    enableThinking: false
                )
            )
            return ["ok": .bool(true), "model": .string(modelID), "text": .string(completion.content)]
        }
    }

    private var generateImage: NativTool {
        NativTool(
            name: ChatImageToolRegistry.generateToolName,
            description: "Generate an image with a local image model and return the file paths.",
            parameters: NativTool.schema(
                properties: [
                    "prompt": NativTool.text("What to draw."),
                    "model": NativTool.text("Image model to use. Defaults to the one chosen in Nativ."),
                    "width": NativTool.number("Pixel width."),
                    "height": NativTool.number("Pixel height."),
                    "count": NativTool.number("How many images to make."),
                    "seed": NativTool.number("Seed for repeatable output."),
                ],
                required: ["prompt"]
            )
        ) { [model] arguments in
            let prompt = try arguments.required("prompt")
            let settings = try await Self.runningSettings(model)
            guard let modelID = arguments.string("model") ?? settings.imageGenerationModelID else {
                throw NativToolError.missingArgument("model")
            }

            var request = ImageRequestSettings()
            request.count = arguments.integer("count") ?? request.count
            request.width = arguments.integer("width") ?? request.width
            request.height = arguments.integer("height") ?? request.height

            let images = try await ImageGenerationExecutor().run(
                baseURL: settings.serverBaseURL,
                apiKey: settings.serverAPIKey,
                modelID: modelID,
                prompt: prompt,
                references: [],
                settings: request,
                seed: arguments.integer("seed")
            )
            return [
                "ok": .bool(true),
                "model": .string(modelID),
                "paths": .array(try Self.write(images).map { .string($0) }),
            ]
        }
    }

    private var transcribeAudio: NativTool {
        NativTool(
            name: "transcribe_audio",
            description: "Transcribe an audio file on this Mac with a local speech-to-text model.",
            parameters: NativTool.schema(
                properties: [
                    "path": NativTool.text("Path to the audio file."),
                    "model": NativTool.text("Model to use. Defaults to the installed speech model."),
                ],
                required: ["path"]
            )
        ) { [model] arguments in
            let path = (try arguments.required("path") as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw NativToolError.fileNotFound(path)
            }
            let transcription = try await NativTranscriptionRunner(
                configuration: await model.voiceTranscriptionConfiguration()
            )
            .transcribe(fileURL: URL(filePath: path), requestedModelID: arguments.string("model"))
            return [
                "ok": .bool(true),
                "model": .string(transcription.modelID),
                "text": .string(transcription.text),
            ]
        }
    }

    private var loadModel: NativTool {
        NativTool(
            name: "load_model",
            description: "Make Nativ load a local language model, restarting its server if needed.",
            parameters: NativTool.schema(
                properties: ["model": NativTool.text("Model repository id to load.")],
                required: ["model"]
            )
        ) { [model] arguments in
            let modelID = try arguments.required("model")
            let settings = await model.settings.normalized()
            let installed = try await LocalModelDiscovery.scan(
                searchPaths: settings.localModelSearchPaths
            )
            guard installed.contains(where: {
                $0.repoID == modelID && $0.capabilities.contains(.text)
            }) else {
                return [
                    "ok": .bool(false),
                    "model": .string(modelID),
                    "error": .string("That model is not installed as a language model, so nothing changed."),
                ]
            }

            await model.switchLanguageModel(to: modelID)
            guard await Self.wait(forSeconds: 240, until: { !model.modelSwitchInProgress }) else {
                throw NativToolError.timedOut("Loading \(modelID)")
            }
            if let failure = await model.modelLoadFailure {
                return [
                    "ok": .bool(false),
                    "model": .string(modelID),
                    "error": .string(failure.message),
                ]
            }
            return await [
                "ok": .bool(true),
                "model": .string(modelID),
                "server_is_running": .bool(model.isRunning),
            ]
        }
    }

    private var startServer: NativTool {
        server(named: "start_server", description: "Start Nativ's local model server.", running: true)
    }

    private var stopServer: NativTool {
        server(named: "stop_server", description: "Stop Nativ's local model server.", running: false)
    }

    private func server(named name: String, description: String, running: Bool) -> NativTool {
        NativTool(name: name, description: description, parameters: NativTool.schema()) { [model] _ in
            if running {
                await model.startServer()
            } else {
                await model.stopServer()
            }
            guard await Self.wait(forSeconds: 180, until: { model.isRunning == running }) else {
                throw NativToolError.timedOut(running ? "Starting the server" : "Stopping the server")
            }
            return ["ok": .bool(true), "server_is_running": .bool(running)]
        }
    }

    private static func runningSettings(_ model: NativModel) async throws -> NativSettings {
        guard await model.isRunning else {
            throw NativToolError.serverNotRunning
        }
        return await model.settings.normalized()
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
}
