import ArgumentParser
import Foundation

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or set the CLI configuration (cli.json).",
        discussion: """
        The CLI resolves each setting flags → environment → cli.json → default,
        so anything set here is a fallback the app (or a flag) can override.
        The Nativ app writes this file on launch; `config set` lets you configure
        the CLI standalone.
        """,
        subcommands: [Show.self, Set.self, Path.self],
        defaultSubcommand: Show.self
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the resolved configuration and its sources.")
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            let c = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: nil)
            func line(_ k: String, _ v: String?) { print("  \(k.padding(toLength: 16, withPad: " ", startingAt: 0))\(v ?? "—")") }
            print("Resolved configuration:")
            line("base-url", c.baseURL.absoluteString)
            line("api-key", c.apiKey.map { _ in "•••• (set)" })
            line("model", c.defaultModel)
            line("embedding-model", c.embeddingModel)
            line("image-model", c.imageModel)
            line("stt-model", c.sttModel)
            line("tts-model", c.ttsModel)
            line("model-path", c.modelSearchPath)
            print("\ncli.json: \(NativConfig.filePath)\(FileManager.default.fileExists(atPath: NativConfig.filePath) ? "" : " (not written yet)")")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write one or more values into cli.json.")
        @Option(name: .customLong("base-url"), help: "Server base URL.") var baseURL: String?
        @Option(name: .customLong("api-key"), help: "API key.") var apiKey: String?
        @Option(name: .customLong("model"), help: "Default (chat/VLM) model id.") var model: String?
        @Option(name: .customLong("embedding-model"), help: "Model for `nativ embed`.") var embeddingModel: String?
        @Option(name: .customLong("image-model"), help: "Model for `nativ image`.") var imageModel: String?
        @Option(name: .customLong("stt-model"), help: "Model for `nativ transcribe`.") var sttModel: String?
        @Option(name: .customLong("tts-model"), help: "Model for `nativ speak`.") var ttsModel: String?
        @Option(name: .customLong("model-path"), help: "Directory scanned by `nativ models list`.") var modelPath: String?

        func run() async throws {
            let all = [baseURL, apiKey, model, embeddingModel, imageModel, sttModel, ttsModel, modelPath]
            guard all.contains(where: { $0 != nil }) else {
                throw CLIError.usage("Nothing to set. Pass one or more of --base-url/--api-key/--model/--embedding-model/--image-model/--stt-model/--tts-model/--model-path.")
            }
            try NativConfig.write(
                baseURL: baseURL, apiKey: apiKey, defaultModel: model,
                embeddingModel: embeddingModel, imageModel: imageModel,
                sttModel: sttModel, ttsModel: ttsModel, modelSearchPath: modelPath
            )
            print("Updated \(NativConfig.filePath)")
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the path to cli.json.")
        func run() async throws { print(NativConfig.filePath) }
    }
}
