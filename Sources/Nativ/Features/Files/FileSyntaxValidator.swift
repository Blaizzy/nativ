import Foundation
import NativServerKit

struct FileSyntaxValidator: Sendable {
    func newIssues(
        at url: URL,
        before: String?,
        after: String?
    ) async -> [String] {
        guard let after else { return [] }
        let beforeIssues: [String]
        if let before {
            beforeIssues = await issues(at: url, content: before)
        } else {
            beforeIssues = []
        }
        let existing = Set(beforeIssues)
        let afterIssues = await issues(at: url, content: after)
        return afterIssues.filter { !existing.contains($0) }
    }

    private func issues(at url: URL, content: String) async -> [String] {
        switch url.pathExtension.lowercased() {
        case "json":
            guard let data = content.data(using: .utf8) else { return ["Invalid UTF-8 JSON."] }
            do {
                _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                return []
            } catch {
                return ["JSON: \(error.localizedDescription)"]
            }
        case "py":
            return await pythonIssues(
                content: content,
                script: "import ast,sys; ast.parse(sys.stdin.read())",
                label: "Python"
            )
        case "toml":
            return await pythonIssues(
                content: content,
                script: "import sys,tomllib; tomllib.loads(sys.stdin.read())",
                label: "TOML"
            )
        case "yaml", "yml":
            return await pythonIssues(
                content: content,
                script: "import sys,yaml; yaml.safe_load(sys.stdin.read())",
                label: "YAML"
            )
        default:
            return []
        }
    }

    private func pythonIssues(content: String, script: String, label: String) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let distributionURL = try? Nativ.distributionURL() else { return [] }
            let pythonURL = distributionURL.appendingPathComponent("python/bin/python3")
            guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else { return [] }

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = pythonURL
            process.arguments = ["-c", script]
            process.environment = [
                "PYTHONHOME": distributionURL.appendingPathComponent("python").path,
                "PYTHONNOUSERSITE": "1",
                "PYTHONUTF8": "1",
            ]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output

            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(content.utf8))
                try input.fileHandleForWriting.close()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline {
                    if Task.isCancelled {
                        process.terminate()
                        process.waitUntilExit()
                        return []
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    return []
                }
                guard process.terminationStatus != 0 else { return [] }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data.prefix(4_000), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ["\(label): \(message.isEmpty ? "syntax validation failed" : message)"]
            } catch {
                return []
            }
        }.value
    }
}
