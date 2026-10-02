import AppKit
import Combine
import Darwin
import SwiftUI
import SwiftTerm

struct ChatWorkTerminalReceipt: Equatable {
    let instanceID: UUID
    let inputVersion: Int
}

/// Owns the native views as well as the processes, so changing tabs never starts a second shell.
@MainActor
final class ChatWorkTerminalPool {
    private var sessions: [UUID: [UUID: ChatWorkTerminalSession]] = [:]

    func session(for item: ChatWorkItem, sessionID: UUID, directory: String, startupError: String? = nil) -> ChatWorkTerminalSession {
        if let session = sessions[sessionID]?[item.id] { return session }
        let session = ChatWorkTerminalSession(item: item, directory: directory, startupError: startupError)
        sessions[sessionID, default: [:]][item.id] = session
        return session
    }

    func existing(itemID: UUID, sessionID: UUID) -> ChatWorkTerminalSession? {
        sessions[sessionID]?[itemID]
    }

    func hasRunningCommand(sessionID: UUID) -> Bool {
        sessions[sessionID]?.values.contains { $0.commandIsRunning } ?? false
    }

    func remove(itemID: UUID, sessionID: UUID) {
        sessions[sessionID]?.removeValue(forKey: itemID)?.stop()
    }

    func remove(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)?.values.forEach { $0.stop() }
    }

    isolated deinit {
        for session in sessions.values.flatMap({ $0.values }) { session.stop() }
    }
}

@MainActor
final class ChatWorkTerminalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let view: TerminalView
    let isInteractive: Bool
    @Published private(set) var directory: String
    @Published private(set) var status: String
    @Published private(set) var isRunning = false
    var onStop: (() -> Void)?
    private var didStart = false
    private var previousOutputWasCR = false
    private let initialDirectory: String
    private let instanceID = UUID()
    private var inputVersion = 0
    private var integration: ChatWorkShellIntegration?
    private var markerBuffer = Data()
    private(set) var atPrompt = false
    private(set) var lastExitCode: Int?
    private var inputIsClean = true
    private var commandStarted = false
    private var commandPending = false

    var receipt: ChatWorkTerminalReceipt { .init(instanceID: instanceID, inputVersion: inputVersion) }
    var commandIsRunning: Bool { isInteractive ? isRunning && (!atPrompt || commandPending) : isRunning }

    private let startupError: String?

    init(item: ChatWorkItem, directory: String, startupError: String? = nil) {
        self.startupError = startupError
        isInteractive = item.terminalCommand == nil
        self.directory = directory
        initialDirectory = directory
        status = isInteractive ? "Shell" : "Finished"
        let options = TerminalOptions(scrollback: 2_000)
        if isInteractive {
            view = ChatWorkLocalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 450),
                                            font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        } else {
            // No input delegate: saved and running agent commands are output-only.
            view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 450),
                                font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        }
        super.init()
        (view as? LocalProcessTerminalView)?.processDelegate = self
        if let terminal = view as? ChatWorkLocalTerminalView {
            terminal.onOutput = { [weak self] bytes in self?.observeShellOutput(bytes) }
            terminal.onUserInput = { [weak self] in
                self?.inputVersion += 1
                self?.inputIsClean = false
            }
        }
        view.setAccessibilityLabel(isInteractive ? "Terminal" : "Agent terminal output")
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        if !item.content.isEmpty { append(item.content + "\n\n") }
    }

    isolated deinit {
        stop()
        if let integration { try? FileManager.default.removeItem(at: integration.folder) }
    }

    func startIfNeeded(shell: String = "/bin/zsh", arguments: [String] = ["-l"], environment override: [String: String]? = nil) {
        guard isInteractive, !didStart, let terminal = view as? LocalProcessTerminalView else { return }
        didStart = true
        if let startupError {
            status = "Folder unavailable"
            append(startupError + "\n")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: initialDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            status = "Folder unavailable"
            append("The terminal folder is unavailable: \(initialDirectory)\n")
            return
        }
        var environment = override ?? ProcessInfo.processInfo.environment
        // A preview app's isolated Foundation profile must not change shell tools' home directory.
        environment.removeValue(forKey: "CFFIXED_USER_HOME")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Nativ"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        if shell == "/bin/zsh", !arguments.contains("-f") {
            do {
                let integration = try ChatWorkShellIntegration()
                self.integration = integration
                environment["NATIV_TERMINAL_USER_ZDOTDIR"] = environment["ZDOTDIR"] ?? environment["HOME"] ?? initialDirectory
                environment["ZDOTDIR"] = integration.folder.path
            } catch {
                append("Shell integration could not start. You can still use this terminal manually.\n")
            }
        }
        terminal.startProcess(executable: shell, args: arguments,
                              environment: environment.map { "\($0.key)=\($0.value)" },
                              currentDirectory: initialDirectory)
        isRunning = terminal.process.running
        status = isRunning ? URL(fileURLWithPath: shell).lastPathComponent : "Could not start shell"
    }

    func run(_ command: String, timeout: Int, approvedReceipt: ChatWorkTerminalReceipt) async throws {
        guard receipt == approvedReceipt else {
            throw ChatWorkError.invalid("Terminal input changed while awaiting approval. Read the terminal and retry.")
        }
        guard isInteractive, isRunning, atPrompt, inputIsClean, !commandPending,
              let terminal = view as? LocalProcessTerminalView else {
            throw ChatWorkError.invalid("The terminal is not at an empty shell prompt. Read it, finish or interrupt its current input, then retry.")
        }
        inputVersion += 1
        atPrompt = false
        commandPending = true
        commandStarted = false
        lastExitCode = nil
        // Bracketed paste submits multiline commands as a single shell input.
        // When disabled by shell configuration, quote multiline input for eval.
        let input: String
        if terminal.getTerminal().bracketedPasteMode {
            input = "\u{1b}[200~" + command + "\u{1b}[201~\r"
        } else if command.contains("\n") {
            input = "eval -- " + ChatWorkShellIntegration.quote(command) + "\r"
        } else {
            input = command + "\r"
        }
        terminal.process.send(data: Array(input.utf8)[...])
        do {
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while isRunning, commandPending, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            interrupt()
            throw error
        }
    }

    func snapshot(itemID: UUID) throws -> String {
        let object: [String: Any] = [
            "id": itemID.uuidString, "kind": "terminal", "content": savedText,
            "cwd": directory, "running": commandIsRunning,
            "shell_running": isRunning, "ready": atPrompt && inputIsClean && !commandPending,
            "exit_code": lastExitCode as Any? ?? NSNull(),
            "actions": isInteractive ? ["run", "read", "inspect", "interrupt"] : ["read", "inspect", "interrupt"]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func observeShellOutput(_ data: Data) {
        guard let integration else { return }
        let prefix = Data("\u{1b}]777;nativ;\(integration.token);".utf8)
        markerBuffer.append(data)
        while let range = markerBuffer.range(of: prefix) {
            guard let end = markerBuffer[range.upperBound...].firstIndex(of: 7) else {
                markerBuffer.removeSubrange(..<range.lowerBound)
                if markerBuffer.count > 16_384 { markerBuffer.removeAll() }
                return
            }
            let payload = String(decoding: markerBuffer[range.upperBound..<end], as: UTF8.self)
            markerBuffer.removeSubrange(...end)
            if payload == "busy" {
                atPrompt = false
                commandStarted = true
                inputVersion += 1
            } else if payload.hasPrefix("ready;") {
                let fields = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let code = Int(fields[1]) else { continue }
                atPrompt = true
                inputIsClean = true
                lastExitCode = code
                directory = String(fields[2])
                if commandStarted { commandPending = false }
                if commandStarted { inputVersion += 1 }
            }
        }
        markerBuffer = Data(markerBuffer.suffix(prefix.count - 1))
    }

    func beginCommand(_ command: String, directory: String) {
        self.directory = directory
        append("$ \(command)\n")
        isRunning = true
        status = "Running"
    }

    func append(_ text: String) {
        // Pipe output has LF, whereas a terminal expects CRLF to reset the column.
        view.feed(text: text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func appendOutput(_ data: Data) {
        var bytes: [UInt8] = []
        for byte in data {
            if byte == 10, !previousOutputWasCR { bytes.append(13) }
            bytes.append(byte)
            previousOutputWasCR = byte == 13
        }
        view.feed(byteArray: bytes[...])
    }

    func finish(_ result: TerminalProcessResult) {
        isRunning = false
        onStop = nil
        status = result.timedOut ? "Timed out" : result.terminationSignal.map { "Signal \($0)" }
            ?? "Exit \(result.exitCode ?? -1)"
        append("\n[\(status)]\n\n")
    }

    func finish(error: Error) {
        isRunning = false
        onStop = nil
        status = error is CancellationError ? "Stopped" : "Failed"
        append("\n[\(status)]\n")
    }

    var text: String {
        let terminal = view.getTerminal()
        // Selection export resolves extended Unicode cells and joins wrapped lines.
        // The terminal clamps the final row to the end of its scrollback buffer.
        return terminal.getText(start: Position(col: 0, row: 0),
                                end: Position(col: terminal.cols, row: Int.max))
            .trimmingCharacters(in: .newlines)
    }

    var savedText: String {
        // Do not persist credentials accidentally printed by a command.
        String(FileReadSecretRedactor.redact(text).text.suffix(60_000))
    }

    func interrupt() {
        guard isRunning else { return }
        if let terminal = view as? LocalProcessTerminalView { terminal.send([3]) }
        else { onStop?() }
    }

    func stop() {
        onStop?()
        onStop = nil
        guard let terminal = view as? LocalProcessTerminalView, terminal.process.running else { return }
        // Stop the foreground job too. Interactive shells can ignore SIGTERM.
        let foreground = tcgetpgrp(terminal.process.childfd)
        if foreground > 0, foreground != getpgrp() { kill(-foreground, SIGHUP) }
        let pid = terminal.process.shellPid
        if pid > 0, getpgid(pid) == pid, pid != foreground { kill(-pid, SIGHUP) }
        terminal.terminate()
        // SwiftTerm's explicit terminate cancels its exit monitor. Reap the child
        // ourselves so closing a tab never leaves a zombie (or an ignoring shell).
        if pid > 0 {
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                for _ in 0..<50 {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid || (result == -1 && errno != EINTR) { return }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        isRunning = false
        status = "Closed"
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        self.directory = url.path
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        atPrompt = false
        commandPending = false
        inputVersion += 1
        status = "Exited\(exitCode.map { " (\($0))" } ?? "")"
    }
}

/// Reports prompt boundaries without changing commands or displaying protocol text.
/// User startup files still run, and their ZDOTDIR is restored before the first prompt.
private struct ChatWorkShellIntegration {
    let folder: URL
    let token = UUID().uuidString

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nativ-shell-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        for name in [".zshenv", ".zprofile", ".zshrc"] {
            var source = """
            ZDOTDIR="$NATIV_TERMINAL_USER_ZDOTDIR"
            if [[ -r "$ZDOTDIR/\(name)" ]]; then builtin source "$ZDOTDIR/\(name)"; fi
            export NATIV_TERMINAL_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
            """
            if name == ".zshrc" {
                source += """

                function __nativ_work_ready() {
                    local nativ_exit=$?
                    builtin printf '\\033]777;nativ;\(token);ready;%s;%s\\007' "$nativ_exit" "$PWD"
                    return 0
                }
                function __nativ_work_busy() {
                    builtin printf '\\033]777;nativ;\(token);busy\\007'
                }
                precmd_functions=(__nativ_work_ready ${precmd_functions:#__nativ_work_ready})
                preexec_functions=(__nativ_work_busy ${preexec_functions:#__nativ_work_busy})
                unset NATIV_TERMINAL_USER_ZDOTDIR
                """
            } else {
                source += "\nexport ZDOTDIR=\(Self.quote(folder.path))\n"
            }
            try source.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class ChatWorkLocalTerminalView: LocalProcessTerminalView {
    var onOutput: ((Data) -> Void)?
    var onUserInput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(Data(slice))
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?()
        super.send(source: source, data: data)
    }
}

struct ChatWorkTerminalPane: View {
    @ObservedObject var session: ChatWorkTerminalSession
    let restart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(session.directory).lineLimit(1).truncationMode(.middle).help(session.directory)
                Spacer(minLength: 8)
                Text(session.status).foregroundStyle(.secondary)
                Menu {
                    Button("Copy output", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.text, forType: .string)
                    }
                    Button("Interrupt", systemImage: "stop") { session.interrupt() }
                        .disabled(!session.isRunning)
                    if session.isInteractive {
                        Button("Restart shell", systemImage: "arrow.clockwise", action: restart)
                            .disabled(session.isRunning)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Terminal actions")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
            ChatWorkTerminalView(session: session)
                .id(ObjectIdentifier(session))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .onAppear { session.startIfNeeded() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatWorkTerminalView: NSViewRepresentable {
    let session: ChatWorkTerminalSession
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalView { session.view }
    func updateNSView(_ view: TerminalView, context: Context) {
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
    }
}
