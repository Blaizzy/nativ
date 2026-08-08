import ArgumentParser
import Foundation

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and manage models.",
        subcommands: [List.self, Use.self, Pull.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List models the server can serve.")
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: nil)
            let client = ServerClient(config: config)
            guard await client.isUp() else {
                throw CLIError.server("not reachable at \(config.baseURL.absoluteString). Start it with `nativ serve`.")
            }
            let models = try await client.models()
            if models.isEmpty { print("No models reported."); return }
            for m in models {
                print("\(m == config.defaultModel ? "* " : "  ")\(m)")
            }
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the default model for `nativ run`.")
        @Argument(help: "Model id.") var id: String
        func run() async throws {
            try NativConfig.setDefaultModel(id)
            print("Default model set to \(id).")
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download a model from Hugging Face.")
        @Argument(help: "Hugging Face repo id.") var id: String
        func run() async throws {
            guard let hf = Self.which("huggingface-cli") ?? Self.which("hf") else {
                print("huggingface-cli not found — the server will download \(id) on first use, or `pip install huggingface_hub`.")
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hf)
            process.arguments = ["download", id]
            try process.run()
            process.waitUntilExit()
        }

        private static func which(_ tool: String) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["which", tool]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (out?.isEmpty == false) ? out : nil
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a downloaded model from the model search path.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .shortAndLong, help: "Delete without confirmation.") var force = false
        @Argument(help: "Model id / folder name, relative to the model search path.") var id: String
        func run() async throws {
            let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: nil)
            guard let base = config.modelSearchPath else {
                throw CLIError.usage("No model search path configured (set NATIV_MODEL_PATH or configure it in the app).")
            }
            let dir = URL(fileURLWithPath: (base as NSString).expandingTildeInPath).appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                throw CLIError.notFound("Not found: \(dir.path)")
            }
            if !force {
                print("Delete \(dir.path)? [y/N] ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else { print("Cancelled."); return }
            }
            try FileManager.default.removeItem(at: dir)
            print("Removed \(dir.path)")
        }
    }
}
