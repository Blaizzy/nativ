import ArgumentParser
import Foundation

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a response to a prompt (streams to stdout).",
        discussion: "Delegates to the bundled mlx-vlm CLI, which reuses a running server or loads locally when needed."
    )

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Model id to use (default: the configured model).") var model: String?
    @Option(name: .long, help: "System prompt.") var system: String?
    @Option(name: .customLong("image"), help: "Path to an image to include (repeatable).") var images: [String] = []
    @Flag(name: .customLong("no-stream"), help: "Wait for the whole response, then print it.") var noStream = false
    @Flag(name: .long, help: "Print the raw JSON completion response (implies --no-stream). For scripting.") var json = false
    @Argument(help: "The prompt. If omitted, read from stdin.") var promptWords: [String] = []

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        guard let modelID = config.defaultModel else {
            throw CLIError.usage("No model set. Pass --model <id> or run `nativ models use <id>`.")
        }
        let prompt = resolvePrompt()
        guard !prompt.isEmpty else { throw CLIError.usage("No prompt. Pass text or pipe it via stdin.") }

        let client = ServerClient(config: config)
        if json {
            guard await client.isUp() else {
                throw CLIError.usage("--json needs the server. Start it with `nativ serve`, then retry.")
            }
            try await runOnServer(client: client, model: modelID, prompt: prompt)
        } else if let python = EngineProcess.locatePython() {
            try runWithEngine(python: python, config: config, model: modelID, prompt: prompt)
        } else if await client.isUp() {
            try await runOnServer(client: client, model: modelID, prompt: prompt)
        } else {
            throw CLIError.server("no server running at \(config.baseURL.absoluteString) and no bundled engine found. Start one with `nativ serve`, or point NATIV_ENGINE_BIN at a python3.")
        }
    }

    private func runOnServer(client: ServerClient, model modelID: String, prompt: String) async throws {
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(try userMessage(text: prompt))

        if json {
            print(try await client.chatJSON(model: modelID, messages: messages))
            return
        }
        var full = ""
        try await client.streamChat(model: modelID, messages: messages) { delta in
            full += delta
            if !noStream { FileHandle.standardOutput.write(Data(delta.utf8)) }
        }
        if noStream {
            print(full)
        } else if !full.hasSuffix("\n") {
            print("")
        }
    }

    private func runWithEngine(python: URL, config: NativConfig, model modelID: String, prompt: String) throws {
        var args = [
            "-m", "mlx_vlm.generate",
            "--model", modelID,
            "--prompt", prompt,
            "--base-url", config.baseURL.absoluteString,
            noStream ? "--no-verbose" : "--verbose",
        ]
        if let apiKey = config.apiKey, !apiKey.isEmpty { args += ["--api-key", apiKey] }
        if let system, !system.isEmpty { args += ["--system", system] }
        for path in images {
            args += ["--image", (path as NSString).expandingTildeInPath]
        }
        let process = Process()
        process.executableURL = python
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"   // keep the child's stderr clean
        process.environment = env
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CLIError.server("local generation exited with status \(process.terminationStatus)")
        }
    }

    private func resolvePrompt() -> String {
        let joined = promptWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
        if isatty(fileno(stdin)) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ""
    }

    private func userMessage(text: String) throws -> [String: Any] {
        guard !images.isEmpty else { return ["role": "user", "content": text] }
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for path in images {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data = try Data(contentsOf: url)
            let dataURL = "data:\(Self.mime(for: url.pathExtension));base64,\(data.base64EncodedString())"
            parts.append(["type": "image_url", "image_url": ["url": dataURL]])
        }
        return ["role": "user", "content": parts]
    }

    private static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }
}
