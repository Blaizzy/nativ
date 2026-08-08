import ArgumentParser
import Foundation

struct Image: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate an image via /v1/images/generations.")

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Image model id.") var model: String?
    @Option(name: .shortAndLong, help: "Output file path.") var out: String = "nativ-image.png"
    @Option(name: .long, help: "Size, e.g. 1024x1024.") var size: String?
    @Argument(help: "The image prompt.") var promptWords: [String] = []

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        guard let modelID = config.defaultModel else {
            throw CLIError.usage("No model set. Pass --model <image-model>.")
        }
        let prompt = promptWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw CLIError.usage("No prompt.") }

        let client = ServerClient(config: config)
        let data = try await client.generateImage(model: modelID, prompt: prompt, size: size)
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try data.write(to: url)
        print("Saved \(url.path)")
    }
}
