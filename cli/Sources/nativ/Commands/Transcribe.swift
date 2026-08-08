import ArgumentParser
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an audio file via /v1/audio/transcriptions.")

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Speech-to-text model id.") var model: String?
    @Argument(help: "Path to an audio file.") var file: String

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        guard let modelID = config.resolvedSTTModel else {
            throw CLIError.usage("No speech-to-text model set. Pass --model <id>, set NATIV_STT_MODEL, or `nativ config set --stt-model <id>`.")
        }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound("No such file: \(url.path)")
        }
        let client = ServerClient(config: config)
        let text = try await client.transcribe(fileURL: url, model: modelID)
        print(text)
    }
}
