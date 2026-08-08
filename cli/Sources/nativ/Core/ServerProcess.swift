import Foundation

/// Locates and launches the bundled `mlx-vlm-server` that ships inside Nativ.app,
/// and tracks a CLI-started instance via a pidfile. The binary path is a stable
/// resource location, not app code.
enum ServerProcess {
    static var pidFile: String { (NativConfig.supportDir as NSString).appendingPathComponent("cli-server.pid") }

    /// The bundled server binary, searched via env override then known app locations.
    static func locateBinary() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["NATIV_SERVER_BIN"] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        let relative = "Contents/Frameworks/NativServerKit.framework/Versions/A/Resources/mlx-vlm-server/bin/mlx-vlm-server"
        let apps = [
            "/Applications/Nativ.app",
            ("~/Applications/Nativ.app" as NSString).expandingTildeInPath,
            ("~/Downloads/Nativ-dev-cpu-gpu/Nativ.app" as NSString).expandingTildeInPath,
        ]
        for app in apps {
            let url = URL(fileURLWithPath: app).appendingPathComponent(relative)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
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
