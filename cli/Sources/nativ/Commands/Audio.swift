import ArgumentParser
import Foundation

/// Audio generation and processing. Text-to-speech today; this group is the
/// home for other audio-out tasks (separation, enhancement, SFX, …) as the
/// server grows endpoints for them — each a thin reflection of one endpoint.
struct Audio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Generate or process audio (text-to-speech today).",
        subcommands: [Speak.self]
    )

    struct Speak: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Synthesize speech from text via /v1/audio/speech.")

        @OptionGroup var global: GlobalOptions
        @Option(name: .shortAndLong, help: "Text-to-speech model id.") var model: String?
        @Option(name: .shortAndLong, help: "Output file path (extension picks the format unless --format is given).") var out: String?
        @Option(name: .long, help: "Voice id.") var voice: String?
        @Option(name: .long, help: "Speaking speed (1.0 = normal).") var speed: Double?
        @Option(name: .long, help: "Audio format: mp3, wav, flac, …") var format: String?
        @Argument(help: "The text to speak. If omitted, read from stdin.") var textWords: [String] = []

        func run() async throws {
            let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
            guard let modelID = config.resolvedTTSModel else {
                throw CLIError.usage("No text-to-speech model set. Pass --model <id>, set NATIV_TTS_MODEL, or `nativ config set --tts-model <id>`.")
            }
            let text = resolveText()
            guard !text.isEmpty else { throw CLIError.usage("No text. Pass text or pipe it via stdin.") }

            // The format follows --format, else the output extension, else mp3.
            let outExt = out.map { ($0 as NSString).pathExtension.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
            let fmt = format ?? outExt ?? "mp3"
            let outPath = out ?? "nativ-speech.\(fmt)"

            let client = ServerClient(config: config)
            let data = try await client.speak(model: modelID, input: text, voice: voice, speed: speed, format: fmt)
            let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            try data.write(to: url)
            print("Saved \(url.path)")
        }

        private func resolveText() -> String {
            let joined = textWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
            if isatty(fileno(stdin)) == 0 {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            return ""
        }
    }
}
