import ArgumentParser
import Foundation

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether the server is running and which models it serves.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let config = NativConfig.resolve(baseURL: global.baseURL, apiKey: global.apiKey, model: nil)
        let client = ServerClient(config: config)
        let up = await client.isUp()

        print("Server:  \(up ? "running" : "not reachable")  (\(config.baseURL.absoluteString))")
        if let pid = ServerProcess.readPID(), ServerProcess.isAlive(pid) {
            print("Managed: pid \(pid) (started by `nativ serve`)")
        }
        if let model = config.defaultModel {
            print("Default: \(model)")
        }
        if up {
            let models = (try? await client.models()) ?? []
            if !models.isEmpty {
                print("Models:")
                for m in models { print("  \(m)") }
            }
        }
    }
}
