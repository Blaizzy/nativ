import Foundation

struct NativFunnelStatus: Equatable, Sendable {
    var isInstalled = false
    var publicHost: String?
    var isServing = false
}

struct NativFunnelIntegration: Sendable {
    static let downloadURL = URL(string: "https://tailscale.com/download/mac")!

    private static let searchPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    let port: Int

    func status() async -> NativFunnelStatus {
        guard let executable = Self.executable else {
            return NativFunnelStatus()
        }
        var status = NativFunnelStatus(isInstalled: true)
        let statusOutput = await Self.run(executable, ["status", "--json"])
        if statusOutput.succeeded,
           let data = statusOutput.output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let self0 = object["Self"] as? [String: Any],
           let name = self0["DNSName"] as? String {
            status.publicHost = name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        let funnelOutput = await Self.run(executable, ["funnel", "status"])
        status.isServing = funnelOutput.succeeded
            && funnelOutput.output.contains("127.0.0.1:\(port)")
        return status
    }

    func enable() async -> String? {
        await change(["funnel", "--bg", String(port)])
    }

    func disable() async -> String? {
        await change(["funnel", "off"])
    }

    private func change(_ arguments: [String]) async -> String? {
        guard let executable = Self.executable else {
            return "Tailscale is not installed."
        }
        let result = await Self.run(executable, arguments)
        return result.succeeded ? nil : Self.firstLine(of: result.output)
    }

    private static func firstLine(of output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n").first, !line.isEmpty else {
            return "Tailscale could not change the setting."
        }
        return String(line)
    }

    private static var executable: URL? {
        searchPaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    private struct Output: Sendable {
        let succeeded: Bool
        let output: String
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> Output {
        await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return Output(succeeded: false, output: error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(
                succeeded: process.terminationStatus == 0,
                output: String(decoding: data, as: UTF8.self)
            )
        }
        .value
    }
}
