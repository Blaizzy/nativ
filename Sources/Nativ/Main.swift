import AppKit
import NativServerKit
import SwiftUI

private final class MetricsProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded = false

    func markSucceeded() {
        lock.lock()
        succeeded = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }
}

@main
enum Main {
    @MainActor
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
                let smokeHost = ProcessInfo.processInfo.environment["NATIV_SMOKE_HOST"] ?? "127.0.0.1"
                let smokePort = ProcessInfo.processInfo.environment["NATIV_SMOKE_PORT"] ?? "18080"
                try server.start(arguments: ["--host", smokeHost, "--port", smokePort])
                guard server.isRunning else {
                    fputs("mlx-vlm-server exited before stop was requested\n", stderr)
                    exit(EXIT_FAILURE)
                }
                guard waitForMetricsEndpoint(host: smokeHost, port: smokePort) else {
                    fputs("mlx-vlm-server did not expose /metrics at \(smokeHost):\(smokePort)\n", stderr)
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

        if let index = CommandLine.arguments.firstIndex(of: "--run-routine"),
           index + 1 < CommandLine.arguments.count {
            RoutineHeadlessRun.execute(routineID: CommandLine.arguments[index + 1])
        }

        NativApplication.main()
    }

    private static func waitForMetricsEndpoint(
        host: String,
        port: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if checkMetricsEndpoint(host: host, port: port) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private static func checkMetricsEndpoint(host: String, port: String) -> Bool {
        let urlHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(urlHost):\(port)/metrics") else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = MetricsProbeResult()
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) {
                result.markSucceeded()
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            task.cancel()
        }
        return result.value
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
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
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

            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    appDelegate.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }

            CommandGroup(after: .sidebar) {
                Button("Collapse All Sections") {
                    appDelegate.toggleAllSidebarSections()
                }
                .keyboardShortcut(".", modifiers: [.command, .option])

                Button("Increase Chat Font Size") {
                    appDelegate.increaseChatFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Chat Font Size") {
                    appDelegate.decreaseChatFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Reset Chat Font Size") {
                    appDelegate.resetChatFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

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
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    let appDelegate: AppDelegate

    var body: some View {
        appDelegate.rootView
            .onAppear {
                applyAppearance(appearance)
                appDelegate.registerMainWindowOpener {
                    openWindow(id: "main")
                }
            }
            .onChange(of: appearance) { _, newAppearance in
                applyAppearance(newAppearance)
            }
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = appearance.appKitAppearance
    }
}
