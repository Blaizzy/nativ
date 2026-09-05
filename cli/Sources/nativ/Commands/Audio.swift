import ArgumentParser
import Foundation

/// Audio tasks, mirroring mlx-audio's taxonomy. `tts` and `stt` are wired to the
/// server today; the rest are reserved names until the server exposes them.
enum AudioTask: String, CaseIterable, ExpressibleByArgument {
    case tts   // text-to-speech
    case stt   // speech-to-text
    case sts   // speech-to-speech
    case vad   // voice-activity detection
    case lid   // language identification
}

/// One audio surface driven by `--task`, so the CLI grows with the engine
/// instead of sprouting a command per capability.
struct Audio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Audio tasks: text-to-speech, speech-to-text, and more.",
        discussion: "Tasks mirror mlx-audio: tts, stt, sts, vad, lid. tts and stt are wired to the server; the rest are reserved until the server exposes them."
    )

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Task: tts | stt | sts | vad | lid.") var task: AudioTask
    @Option(name: .shortAndLong, help: "Model id (defaults to the per-task model, then the chat model).") var model: String?
    @Option(name: .shortAndLong, help: "Output file path (tts).") var out: String?
    @Option(name: .long, help: "Voice id (tts).") var voice: String?
    @Option(name: .long, help: "Speaking speed, 1.0 = normal (tts).") var speed: Double?
    @Option(name: .long, help: "Audio format: mp3, wav, flac, … (tts).") var format: String?
    @Argument(help: "Input: text for tts (or stdin); an audio file path for stt.") var input: [String] = []

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        let client = ServerClient(config: config)
        switch task {
        case .tts: try await runTTS(config, client)
        case .stt: try await runSTT(config, client)
        case .sts, .vad, .lid:
            throw CLIError.usage("Task '\(task.rawValue)' isn't supported by the server yet — only tts and stt are wired today.")
        }
    }

    private func runTTS(_ config: NativConfig, _ client: ServerClient) async throws {
        guard let modelID = config.resolvedTTSModel else {
            throw CLIError.usage("No text-to-speech model set. Pass --model <id>, set NATIV_TTS_MODEL, or `nativ config set --tts-model <id>`.")
        }
        let text = resolveText()
        guard !text.isEmpty else { throw CLIError.usage("No text. Pass text or pipe it via stdin.") }

        // The format follows --format, else the output extension, else mp3.
        let outExt = out.map { ($0 as NSString).pathExtension.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let fmt = format ?? outExt ?? "mp3"
        let outPath = out ?? "nativ-speech.\(fmt)"

        let data = try await client.speak(model: modelID, input: text, voice: voice, speed: speed, format: fmt)
        let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
        try data.write(to: url)
        print("Saved \(url.path)")
    }

    private func runSTT(_ config: NativConfig, _ client: ServerClient) async throws {
        guard let modelID = config.resolvedSTTModel else {
            throw CLIError.usage("No speech-to-text model set. Pass --model <id>, set NATIV_STT_MODEL, or `nativ config set --stt-model <id>`.")
        }
        guard let file = input.first else {
            throw CLIError.usage("No audio file. Usage: nativ audio --task stt <audio-file>.")
        }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound("No such file: \(url.path)")
        }
        let text = try await client.transcribe(fileURL: url, model: modelID)
        print(text)
    }

    private func resolveText() -> String {
        let joined = input.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { return joined }
        if isatty(fileno(stdin)) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ""
    }
}
