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
        if let json = await Self.run(executable, ["status", "--json"]),
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let self0 = object["Self"] as? [String: Any],
           let name = self0["DNSName"] as? String {
            status.publicHost = name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        if let served = await Self.run(executable, ["funnel", "status"]) {
            status.isServing = served.contains("127.0.0.1:\(port)")
        }
        return status
    }

    func enable() async -> Bool {
        guard let executable = Self.executable else {
            return false
        }
        return await Self.run(executable, ["funnel", "--bg", String(port)]) != nil
    }

    func disable() async -> Bool {
        guard let executable = Self.executable else {
            return false
        }
        return await Self.run(executable, ["funnel", "off"]) != nil
    }

    private static var executable: URL? {
        searchPaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
        .value
    }
}
