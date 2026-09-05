import Foundation

/// Locates and launches the bundled `mlx-vlm-server` that ships inside Nativ.app,
/// and tracks a CLI-started instance via a pidfile. The binary path is a stable
/// resource location, not app code.
enum ServerProcess {
    static var pidFile: String { (NativConfig.supportDir as NSString).appendingPathComponent("cli-server.pid") }

    /// Known install locations of Nativ.app, most-specific first.
    static let appPaths: [String] = [
        "/Applications/Nativ.app",
        ("~/Applications/Nativ.app" as NSString).expandingTildeInPath,
        ("~/Downloads/Nativ-dev-cpu-gpu/Nativ.app" as NSString).expandingTildeInPath,
    ]

    /// An executable resource inside the app bundle, at `relativePath` under the
    /// app root, or nil if no bundle here has it. Shared by the server and engine
    /// locators.
    static func bundledResource(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        for app in appPaths {
            let url = URL(fileURLWithPath: app).appendingPathComponent(relativePath)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// The bundled server binary, searched via env override then known app locations.
    static func locateBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["NATIV_SERVER_BIN"] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return bundledResource("Contents/Frameworks/NativServerKit.framework/Versions/A/Resources/mlx-vlm-server/bin/mlx-vlm-server")
    }

    static func writePID(_ pid: Int32) {
        try? FileManager.default.createDirectory(atPath: NativConfig.supportDir, withIntermediateDirectories: true)
        try? "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    static func readPID() -> Int32? {
        guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }

    static func clearPID() { try? FileManager.default.removeItem(atPath: pidFile) }

    /// True if a process with `pid` is currently alive.
    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
}
