import ArgumentParser
import Foundation

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the server started by `nativ serve`.")

    func run() async throws {
        guard let pid = ServerProcess.readPID() else {
            print("No CLI-managed server to stop.")
            return
        }
        if ServerProcess.isAlive(pid) {
            kill(pid, SIGTERM)
            print("Stopped server (pid \(pid)).")
        } else {
            print("Server (pid \(pid)) was not running.")
        }
        ServerProcess.clearPID()
    }
}
