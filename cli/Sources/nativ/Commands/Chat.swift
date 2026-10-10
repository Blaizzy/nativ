import ArgumentParser
import Foundation

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive chat session (REPL).",
        discussion: """
        Slash commands:
          /model <id>     switch model for the rest of the session
          /system <text>  set (or replace) the system prompt
          /reset          clear the conversation (keeps the system prompt)
          /help           show these commands
          /exit           quit

        Type three double-quotes on their own line to start a multi-line
        message, and three double-quotes again to send it.
        """
    )

    @OptionGroup var global: GlobalOptions
    @Option(name: .shortAndLong, help: "Model id to use (default: the configured model).") var model: String?
    @Option(name: .long, help: "System prompt.") var system: String?

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: model)
        guard var modelID = config.defaultModel else {
            throw CLIError.usage("No model set. Pass --model <id> or run `nativ models use <id>`.")
        }
        let client = ServerClient(config: config)

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }

        print("nativ chat — \(modelID).  /help for commands · /exit quits.")
        while true {
            FileHandle.standardOutput.write(Data("\n› ".utf8))
            guard let line = readLine(strippingNewline: true) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("/") {
                switch handleCommand(trimmed, model: &modelID, messages: &messages) {
                case .handled: continue
                case .exit: return
                case .notACommand: break
                }
            }

            // A lone """ opens a multi-line block, terminated by another """.
            var prompt = trimmed
            if trimmed == "\"\"\"" {
                var lines: [String] = []
                while let l = readLine(strippingNewline: true), l.trimmingCharacters(in: .whitespaces) != "\"\"\"" {
                    lines.append(l)
                }
                prompt = lines.joined(separator: "\n")
                if prompt.isEmpty { continue }
            }

            messages.append(["role": "user", "content": prompt])
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

    private enum CommandResult { case handled, exit, notACommand }

    private func handleCommand(_ input: String, model modelID: inout String, messages: inout [[String: Any]]) -> CommandResult {
        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch command {
        case "/exit", "/quit":
            return .exit
        case "/reset":
            messages = messages.filter { ($0["role"] as? String) == "system" }
            print("(context cleared)")
            return .handled
        case "/model":
            guard !arg.isEmpty else { print("current model: \(modelID)"); return .handled }
            modelID = arg
            print("(model → \(arg))")
            return .handled
        case "/system":
            messages.removeAll { ($0["role"] as? String) == "system" }
            if !arg.isEmpty {
                messages.insert(["role": "system", "content": arg], at: 0)
                print("(system prompt set)")
            } else {
                print("(system prompt cleared)")
            }
            return .handled
        case "/help":
            print("""
            /model <id>     switch model
            /system <text>  set/replace system prompt (empty clears it)
            /reset          clear conversation (keeps system prompt)
            /exit           quit
            \"\"\"             start/end a multi-line message
            """)
            return .handled
        default:
            print("unknown command \(command) — /help for the list")
            return .handled
        }
    }
}
