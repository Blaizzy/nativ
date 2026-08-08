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
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a downloaded model (model search path or the Hugging Face cache).")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .shortAndLong, help: "Delete without confirmation.") var force = false
        @Argument(help: "Model id, e.g. mlx-community/Model.") var id: String
        func run() async throws {
            let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: nil)
            guard let dir = Self.resolveModelDir(id: id, searchPath: config.modelSearchPath) else {
                throw CLIError.notFound("Couldn't find \(id) in the model search path or the Hugging Face cache.")
            }
            if !force {
                print("Delete \(dir.path)? [y/N] ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else { print("Cancelled."); return }
            }
            try FileManager.default.removeItem(at: dir)
            print("Removed \(dir.path)")
        }

        /// Resolve a model id to its on-disk directory: the configured model
        /// search path, else the Hugging Face hub cache (`models--org--name`),
        /// honoring HF_HUB_CACHE / HF_HOME.
        private static func resolveModelDir(id: String, searchPath: String?) -> URL? {
            let fm = FileManager.default
            if let base = searchPath {
                let url = URL(fileURLWithPath: (base as NSString).expandingTildeInPath).appendingPathComponent(id)
                if fm.fileExists(atPath: url.path) { return url }
            }
            let env = ProcessInfo.processInfo.environment
            let hubRoot: String
            if let cache = env["HF_HUB_CACHE"] {
                hubRoot = cache
            } else if let home = env["HF_HOME"] {
                hubRoot = (home as NSString).appendingPathComponent("hub")
            } else {
                hubRoot = ("~/.cache/huggingface/hub" as NSString).expandingTildeInPath
            }
            let cacheName = "models--" + id.replacingOccurrences(of: "/", with: "--")
            let url = URL(fileURLWithPath: hubRoot).appendingPathComponent(cacheName)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }
}
