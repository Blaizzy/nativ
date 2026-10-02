import ArgumentParser
import Foundation

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and manage models.",
        subcommands: [List.self, Use.self, Pull.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List available models: those loaded by the server plus any cached locally."
        )
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Only models the running server reports (skip the local cache scan).") var serverOnly = false
        func run() async throws {
            let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: nil)
            let client = ServerClient(config: config)

            let loaded = await client.isUp() ? ((try? await client.models()) ?? []) : []
            let cached = serverOnly ? [] : Self.localModels(searchPath: config.modelSearchPath)

            // Merge, dedup, keeping a note of where each came from.
            var order: [String] = []
            var seen = Set<String>()
            for m in loaded + cached where !seen.contains(m) { seen.insert(m); order.append(m) }
            let loadedSet = Set(loaded)

            guard !order.isEmpty else {
                print(serverOnly || !cached.isEmpty ? "No models found." :
                      "No models found. Server not running and nothing cached locally.")
                return
            }
            for m in order.sorted() {
                let marker = m == config.defaultModel ? "*" : " "
                let tag = loadedSet.contains(m) ? "loaded" : "cached"
                print("\(marker) \(m)  (\(tag))")
            }
        }

        /// Model ids present on disk: the configured search path (one dir per
        /// model) and the Hugging Face hub cache (`models--org--name`).
        private static func localModels(searchPath: String?) -> [String] {
            let fm = FileManager.default
            var ids: [String] = []

            if let base = searchPath {
                let root = (base as NSString).expandingTildeInPath
                if let entries = try? fm.contentsOfDirectory(atPath: root) {
                    for e in entries where !e.hasPrefix(".") {
                        var isDir: ObjCBool = false
                        let full = (root as NSString).appendingPathComponent(e)
                        // Support both flat (`Model`) and `org/name` layouts.
                        if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                            if let subs = try? fm.contentsOfDirectory(atPath: full),
                               subs.contains(where: { $0.hasSuffix(".safetensors") || $0 == "config.json" }) {
                                ids.append(e)
                            } else if let subs = try? fm.contentsOfDirectory(atPath: full) {
                                for s in subs where !s.hasPrefix(".") { ids.append("\(e)/\(s)") }
                            }
                        }
                    }
                }
            }

            let env = ProcessInfo.processInfo.environment
            let hubRoot: String
            if let cache = env["HF_HUB_CACHE"] { hubRoot = cache }
            else if let home = env["HF_HOME"] { hubRoot = (home as NSString).appendingPathComponent("hub") }
            else { hubRoot = ("~/.cache/huggingface/hub" as NSString).expandingTildeInPath }
            if let entries = try? fm.contentsOfDirectory(atPath: hubRoot) {
                for e in entries where e.hasPrefix("models--") {
                    ids.append(e.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/"))
                }
            }
            return ids
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
