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

        let address = "http://\(host):\(port)"
        let serverArgs = ["--host", host, "--port", "\(port)"] + passthrough

        if detached {
            // Launch via `nohup` so the server ignores SIGHUP and keeps running
            // after the CLI returns / the terminal closes. nohup exec-replaces
            // itself with the server, so its pid is the server's pid.
            try? FileManager.default.createDirectory(atPath: NativConfig.supportDir, withIntermediateDirectories: true)
            let logPath = (NativConfig.supportDir as NSString).appendingPathComponent("server.log")
            FileManager.default.createFile(atPath: logPath, contents: nil)
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            launcher.arguments = [binary.path] + serverArgs
            if let handle = FileHandle(forWritingAtPath: logPath) {
                launcher.standardOutput = handle
                launcher.standardError = handle
            }
            try launcher.run()
            ServerProcess.writePID(launcher.processIdentifier)
            print("Server starting (pid \(launcher.processIdentifier)) at \(address)  ·  logs: \(logPath)")

            // Report readiness honestly so a following `run` doesn't race a
            // still-loading server.
            let client = ServerClient(config: NativConfig.resolve(baseURL: address))
            if await client.waitUntilReady(timeout: 60) {
                print("Server ready.")
            } else {
                print("Server still loading after 60s — check the logs above.")
            }
            return
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = serverArgs
        try process.run()
        ServerProcess.writePID(process.processIdentifier)
        print("Server running at \(address)  (Ctrl-C to stop)")
        process.waitUntilExit()
        ServerProcess.clearPID()
    }
}
