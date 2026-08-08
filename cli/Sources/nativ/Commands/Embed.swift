import ArgumentParser
import Foundation

struct Embed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Embed text via /v1/embeddings (one vector per input).")

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Embedding model id.") var model: String?
    @Flag(name: .long, help: "Print only the vector dimension(s).") var dims = false
    @Argument(help: "Text to embed (repeatable). If omitted, read stdin (one input per line).") var texts: [String] = []

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        guard let modelID = config.defaultModel else {
            throw CLIError.usage("No model set. Pass --model <embedding-model>.")
        }

        var inputs = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if inputs.isEmpty, isatty(fileno(stdin)) == 0 {
            let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            inputs = raw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard !inputs.isEmpty else { throw CLIError.usage("No input. Pass text or pipe via stdin.") }

        let client = ServerClient(config: config)
        let vectors = try await client.embeddings(model: modelID, input: inputs)
        if dims {
            for v in vectors { print(v.count) }
        } else {
            let json = try JSONSerialization.data(withJSONObject: vectors, options: [])
            print(String(data: json, encoding: .utf8) ?? "[]")
        }
    }
}
