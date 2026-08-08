import ArgumentParser
import Foundation

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the local mlx-vlm server (bundled with Nativ.app).")

    @Option(name: .shortAndLong, help: "Port to listen on.") var port: Int = 8080
    @Option(name: .long, help: "Host to bind.") var host: String = "127.0.0.1"
    @Flag(name: .shortAndLong, help: "Run detached in the background.") var detached = false
    @Argument(parsing: .postTerminator, help: "Extra args passed through to mlx-vlm-server (after --).") var passthrough: [String] = []

    func run() async throws {
        guard let binary = ServerProcess.locateBinary() else {
            throw CLIError.notFound("Couldn't find the bundled mlx-vlm-server. Install Nativ.app or set NATIV_SERVER_BIN.")
        }
        if let pid = ServerProcess.readPID(), ServerProcess.isAlive(pid) {
            print("Server already running (pid \(pid)).")
            return
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--host", host, "--port", "\(port)"] + passthrough
        let address = "http://\(host):\(port)"

        if detached {
            // Best-effort background run: detach stdio to a log file so it keeps
            // running after the CLI returns. (Full daemonization via setsid is a TODO.)
            try? FileManager.default.createDirectory(atPath: NativConfig.supportDir, withIntermediateDirectories: true)
            let logPath = (NativConfig.supportDir as NSString).appendingPathComponent("server.log")
            FileManager.default.createFile(atPath: logPath, contents: nil)
            if let handle = FileHandle(forWritingAtPath: logPath) {
                process.standardOutput = handle
                process.standardError = handle
            }
            try process.run()
            ServerProcess.writePID(process.processIdentifier)
            print("Server started (pid \(process.processIdentifier)) at \(address)  ·  logs: \(logPath)")
            return
        }

        try process.run()
        ServerProcess.writePID(process.processIdentifier)
        print("Server running at \(address)  (Ctrl-C to stop)")
        process.waitUntilExit()
        ServerProcess.clearPID()
    }
}
