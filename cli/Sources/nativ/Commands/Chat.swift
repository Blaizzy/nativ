import ArgumentParser
import Foundation

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive chat session (REPL).")

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Model id to use (default: the configured model).") var model: String?
    @Option(name: .long, help: "System prompt.") var system: String?

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        guard let modelID = config.defaultModel else {
            throw CLIError.usage("No model set. Pass --model <id> or run `nativ models use <id>`.")
        }
        let client = ServerClient(config: config)

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }

        print("nativ chat — \(modelID).  /reset clears context · /exit quits.")
        while true {
            FileHandle.standardOutput.write(Data("\n› ".utf8))
            guard let line = readLine(strippingNewline: true) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "/exit" || trimmed == "/quit" { break }
            if trimmed == "/reset" {
                messages = messages.filter { ($0["role"] as? String) == "system" }
                print("(context cleared)")
                continue
            }

            messages.append(["role": "user", "content": trimmed])
            var reply = ""
            do {
                try await client.streamChat(model: modelID, messages: messages) { delta in
                    reply += delta
                    FileHandle.standardOutput.write(Data(delta.utf8))
                }
            } catch {
                print("\n[error] \(error)")
                messages.removeLast()
                continue
            }
            print("")
            messages.append(["role": "assistant", "content": reply])
        }
    }
}
