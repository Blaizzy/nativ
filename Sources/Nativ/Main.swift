import AppKit
import NativServerKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            do {
                let output = try Nativ.run(arguments: ["--help"])
                print(output)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        if CommandLine.arguments.contains("--lifecycle-smoke-test") {
            let server = NativProcessController()
            server.onOutput = { text in
                print(text, terminator: "")
            }
            server.onTermination = { status in
                print("\nmlx-vlm-server stopped with status \(status)")
            }

            do {
                let smokePort = ProcessInfo.processInfo.environment["NATIV_SMOKE_PORT"] ?? "18080"
                try server.start(arguments: ["--host", "127.0.0.1", "--port", smokePort])
                guard server.isRunning else {
                    fputs("mlx-vlm-server exited before stop was requested\n", stderr)
                    exit(EXIT_FAILURE)
                }
                guard waitForMetricsEndpoint(port: smokePort) else {
                    fputs("mlx-vlm-server did not expose /metrics on port \(smokePort)\n", stderr)
                    try? server.stop()
                    exit(EXIT_FAILURE)
                }
                try server.stop()
                Thread.sleep(forTimeInterval: 1)
                guard !server.isRunning else {
                    fputs("mlx-vlm-server was still running after stop\n", stderr)
                    exit(EXIT_FAILURE)
                }
                exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        NativApplication.main()
    }

    private static func waitForMetricsEndpoint(port: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if checkMetricsEndpoint(port: port) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private static func checkMetricsEndpoint(port: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/metrics") else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var didSucceed = false
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse {
                didSucceed = (200..<300).contains(httpResponse.statusCode)
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
        }
        return didSucceed
    }
}

private struct NativApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Nativ", id: "main") {
            NativRootView(appDelegate: appDelegate)
        }
        .defaultSize(width: 1240, height: 720)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: appDelegate.softwareUpdater.updater)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    appDelegate.createNewChat()
                }
                .keyboardShortcut("n")
            }

            SidebarCommands()

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}

private struct NativRootView: View {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        appDelegate.rootView
            .onAppear {
                appDelegate.registerMainWindowOpener {
                    openWindow(id: "main")
                }
            }
    }
}
