import Darwin
import Foundation
import NativServerKit

enum ChatTerminalToolRegistry {
    static let toolName = "terminal"
    static let defaultTimeoutSeconds = 180
    static let maximumTimeoutSeconds = 600

    static let definition = MLXChatToolDefinition(
        function: MLXChatFunctionDefinition(
            name: toolName,
            description:
                "Run a non-interactive local zsh command on the user's Mac. Every call requires explicit user approval. Prefer read_file, search_files, write_file, and patch for file operations.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The complete shell command to run."),
                        "minLength": .number(1),
                    ]),
                    "cwd": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional working directory. Relative paths are resolved from Nativ's default working directory (the project root in a project chat, or the user's home directory otherwise)."
                        ),
                        "minLength": .number(1),
                    ]),
                    "timeout": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum execution time in seconds. Defaults to 180 and may not exceed 600."
                        ),
                        "minimum": .number(1),
                        "maximum": .number(Double(maximumTimeoutSeconds)),
                        "default": .number(Double(defaultTimeoutSeconds)),
                    ]),
                ]),
                "required": .array([.string("command")]),
            ])
        ))
}

struct ChatTerminalToolRequest: Equatable, Sendable {
    let command: String
    let cwd: String?
    let timeoutSeconds: Int

    init(call: MLXChatToolCall) throws {
        guard call.function?.name == ChatTerminalToolRegistry.toolName else {
            throw ChatTerminalToolError.invalidArguments("Unsupported terminal operation.")
        }
        try self.init(argumentsJSON: call.function?.arguments)
    }

    init(argumentsJSON: String?) throws {
        guard let data = argumentsJSON?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let arguments = object as? [String: Any]
        else {
            throw ChatTerminalToolError.invalidArguments(
                "Arguments must be a JSON object containing command."
            )
        }

        let allowedKeys: Set<String> = ["command", "cwd", "timeout"]
        let unknownKeys = Set(arguments.keys).subtracting(allowedKeys)
        guard unknownKeys.isEmpty else {
            throw ChatTerminalToolError.invalidArguments(
                "Unsupported argument(s): \(unknownKeys.sorted().joined(separator: ", "))."
            )
        }
        guard let command = arguments["command"] as? String,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ChatTerminalToolError.invalidArguments(
                "command is required and must be a non-empty string."
            )
        }
        guard !command.contains("\0") else {
            throw ChatTerminalToolError.invalidArguments("command may not contain NUL bytes.")
        }

        let cwd: String?
        if let rawCWD = arguments["cwd"] {
            guard let value = rawCWD as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !value.contains("\0")
            else {
                throw ChatTerminalToolError.invalidArguments(
                    "cwd must be a non-empty string without NUL bytes."
                )
            }
            cwd = value
        } else {
            cwd = nil
        }

        let timeoutSeconds: Int
        if let rawTimeout = arguments["timeout"] {
            guard let number = rawTimeout as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID()
            else {
                throw ChatTerminalToolError.invalidArguments(
                    "timeout must be an integer number of seconds."
                )
            }
            let value = number.doubleValue
            guard value.rounded() == value else {
                throw ChatTerminalToolError.invalidArguments(
                    "timeout must be an integer number of seconds."
                )
            }
            timeoutSeconds = number.intValue
        } else {
            timeoutSeconds = ChatTerminalToolRegistry.defaultTimeoutSeconds
        }
        guard (1 ... ChatTerminalToolRegistry.maximumTimeoutSeconds).contains(timeoutSeconds)
        else {
            throw ChatTerminalToolError.invalidArguments(
                "timeout must be between 1 and \(ChatTerminalToolRegistry.maximumTimeoutSeconds) seconds."
            )
        }

        self.command = command
        self.cwd = cwd
        self.timeoutSeconds = timeoutSeconds
    }
}

struct TerminalCommandAssessment: Equatable, Sendable {
    let blockedReason: String?
    let warnings: [String]
}

enum TerminalCommandSafetyPolicy {
    static func assess(command: String) -> TerminalCommandAssessment {
        let normalized = normalize(command)
        let lowercase = normalized.lowercased()

        if isForkBomb(normalized) {
            return blocked(
                "Fork-bomb commands are blocked and cannot be approved."
            )
        }
        if recursivelyDeletesCatastrophicPath(normalized) {
            return blocked(
                "Recursive deletion of a filesystem root, system root, or the entire home directory is blocked and cannot be approved."
            )
        }
        if matches(#"(?i)\brm\b[^\n;&|]*--no-preserve-root\b"#, in: normalized) {
            return blocked(
                "rm --no-preserve-root is blocked and cannot be approved."
            )
        }
        if matches(
            #"(?i)\b(?:mkfs(?:\.[a-z0-9_+-]+)?|newfs_[a-z0-9_+-]+)\b[^\n;&|]*\s/dev/(?:r?disk)[a-z0-9]*\b"#,
            in: normalized
        ) {
            return blocked(
                "Formatting a physical disk is blocked and cannot be approved."
            )
        }
        if matches(
            #"(?i)\bdd\b[^\n;&|]*\bof\s*=\s*/dev/(?:r?disk)[a-z0-9]*\b"#,
            in: normalized
        ) {
            return blocked(
                "Writing raw data to a physical disk is blocked and cannot be approved."
            )
        }
        if matches(#"(?i)\bdiskutil\s+(?:eraseDisk|zeroDisk|randomDisk)\b"#, in: normalized) {
            return blocked(
                "Erasing a physical disk is blocked and cannot be approved."
            )
        }
        if isPrivilegedRemotePipeToShell(lowercase) {
            return blocked(
                "Piping downloaded code directly into a privileged shell is blocked. Download and inspect it first."
            )
        }

        var warnings: [String] = []
        func warn(_ message: String, when condition: Bool) {
            if condition && !warnings.contains(message) {
                warnings.append(message)
            }
        }

        warn(
            "Requests elevated privileges with sudo.",
            when: matches(#"(?i)(?:^|[;&|]\s*)sudo(?:\s|$)"#, in: normalized)
        )
        warn(
            "Recursively deletes files or directories.",
            when: isRecursiveRM(normalized)
        )
        warn(
            "Changes ownership or broadens filesystem permissions.",
            when: matches(
                #"(?i)\b(?:chmod\s+(?:-R\s+)?(?:777|a\+rwx)|chown\s+-R\b)"#,
                in: normalized
            )
        )
        warn(
            "Downloads code and pipes it directly into an interpreter.",
            when: matches(
                #"(?i)\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:/[^\s]+/)?(?:sh|bash|zsh|python(?:3)?|ruby|perl)\b"#,
                in: normalized
            )
        )
        warn(
            "Uses a destructive Git operation.",
            when: matches(
                #"(?i)\bgit\s+(?:reset\s+--hard|clean\s+(?:-[a-z]*f|--force)|push\b[^\n;&|]*--force|branch\s+-D)\b"#,
                in: normalized
            )
        )
        warn(
            "Stops processes or system services.",
            when: matches(
                #"(?i)\b(?:killall|pkill|launchctl\s+(?:bootout|remove|unload)|systemctl\s+(?:stop|disable|mask)|shutdown|reboot|halt)\b"#,
                in: normalized
            )
        )
        warn(
            "Deletes files through find.",
            when: matches(
                #"(?i)\bfind\b[^\n;&|]*(?:-delete|-exec\s+(?:/[^\s]+/)?rm\b)"#,
                in: normalized
            )
        )
        warn(
            "Contains a potentially destructive database statement.",
            when: matches(
                #"(?i)\b(?:drop\s+(?:database|schema|table)|truncate\s+table|delete\s+from\b(?![^;\n]*\bwhere\b))"#,
                in: normalized
            )
        )
        warn(
            "Accesses a sensitive system or credential location.",
            when: matches(
                #"(?i)(?:^|[\s'\"])(?:/etc(?:/|\b)|/var(?:/|\b)|/root(?:/|\b)|~/(?:\.ssh|\.gnupg)(?:/|\b)|[^\s'\"]*/\.ssh(?:/|\b))"#,
                in: normalized
            )
        )
        warn(
            "Runs inline interpreter code, which can conceal additional operations.",
            when: matches(
                #"(?i)(?:^|[;&|]\s*)(?:/[^\s]+/)?(?:sh|bash|zsh|python(?:3)?|ruby|perl|node)\s+(?:-[a-z]*[ce]|--eval|--command)\b"#,
                in: normalized
            )
        )

        return TerminalCommandAssessment(blockedReason: nil, warnings: warnings)
    }

    static func normalize(_ command: String) -> String {
        var value = command.precomposedStringWithCompatibilityMapping
        value = replacing(#"\x1B\[[0-?]*[ -/]*[@-~]"#, in: value, with: "")
        value = value.replacingOccurrences(of: "\0", with: "")
        value = replacing(#"\\\r?\n"#, in: value, with: " ")
        value = replacing(#"\$\{?IFS\}?"#, in: value, with: " ", options: [.caseInsensitive])
        value = value.replacingOccurrences(of: "''", with: "")
        value = value.replacingOccurrences(of: "\"\"", with: "")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        value = replacing(#"(?<![A-Za-z0-9_])\$\{HOME\}"#, in: value, with: home)
        value = replacing(#"(?<![A-Za-z0-9_])\$HOME\b"#, in: value, with: home)
        value = replacing(#"(?:(?<=^)|(?<=[\s;&|]))~(?=/|\s|$)"#, in: value, with: home)
        return replacing(#"[\t\r\n ]+"#, in: value, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blocked(_ reason: String) -> TerminalCommandAssessment {
        TerminalCommandAssessment(blockedReason: reason, warnings: [])
    }

    private static func isForkBomb(_ command: String) -> Bool {
        let compact =
            command
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return compact.contains(":(){:|:&};:")
    }

    private static func recursivelyDeletesCatastrophicPath(_ command: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let catastrophicTargets: Set<String> = [
            "/", "/*", "/System", "/Library", "/Applications", "/Users", "/private",
            "/usr", "/bin", "/sbin", "/var", "/etc", home, home + "/*",
        ]
        for arguments in rmArgumentStrings(command) {
            let tokens = shellLikeTokens(arguments)
            let recursive =
                tokens.contains("--recursive")
                || tokens.contains { token in
                    token.hasPrefix("-") && !token.hasPrefix("--")
                        && token.dropFirst().lowercased().contains("r")
                }
            guard recursive else { continue }
            let targets = tokens.filter { !$0.hasPrefix("-") }
            if targets.contains(where: catastrophicTargets.contains) {
                return true
            }
        }
        return false
    }

    private static func isRecursiveRM(_ command: String) -> Bool {
        rmArgumentStrings(command).contains { arguments in
            let tokens = shellLikeTokens(arguments)
            return tokens.contains("--recursive")
                || tokens.contains { token in
                    token.hasPrefix("-") && !token.hasPrefix("--")
                        && token.dropFirst().lowercased().contains("r")
                }
        }
    }

    private static func rmArgumentStrings(_ command: String) -> [String] {
        let executablePath = #"(?:[^\s;&|'\"]*/)?"#
        let quotedShellExecutable =
            #"['\"]?"# + executablePath + #"(?:sh|bash|zsh)['\"]?"#
        let shellLauncher =
            #"(?:"# + quotedShellExecutable
            + #"\s+(?:-[^\s;&|]+\s+)*['\"]?\s*)?"#
        let quotedRMExecutable = #"['\"]?"# + executablePath + #"rm['\"]?"#
        let pattern =
            #"(?i)(?:^|[;&|]\s*)(?:sudo\s+)?(?:command\s+)?"#
            + shellLauncher + quotedRMExecutable + #"\s+([^;&|]+)"#
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern
            )
        else { return [] }
        let range = NSRange(command.startIndex..., in: command)
        return regex.matches(in: command, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: command) else { return nil }
            return String(command[swiftRange])
        }
    }

    private static func shellLikeTokens(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace })
            .map {
                String($0).trimmingCharacters(
                    in: CharacterSet(charactersIn: "'\""))
            }
    }

    private static func isPrivilegedRemotePipeToShell(_ command: String) -> Bool {
        let remotePipe = matches(
            #"\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:/[^\s]+/)?(?:sh|bash|zsh)\b"#,
            in: command
        )
        guard remotePipe else { return false }
        return command.contains("sudo ") || command.hasPrefix("sudo")
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}

struct TerminalProcessRequest: Sendable {
    let command: String
    let currentDirectoryURL: URL
    let timeout: TimeInterval
    let environment: [String: String]
}

struct TerminalProcessResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32?
    let terminationSignal: Int32?
    let timedOut: Bool
    let durationMilliseconds: Int
    let outputTruncated: Bool
}

struct ChatTerminalToolDependencies: Sendable {
    typealias Run = @Sendable (TerminalProcessRequest) async throws -> TerminalProcessResult

    let run: Run

    static let live = Self(
        run: { request in
            try await TerminalProcessRunner().run(request)
        }
    )
}

enum ChatTerminalToolError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case approvalRequired
    case blocked(String)
    case invalidWorkingDirectory(String)
    case launchFailed(String)
    case commandFailed(TerminalProcessResult, warnings: [String], redacted: Bool)
    case timedOut(TerminalProcessResult, warnings: [String], redacted: Bool)
}

struct ChatTerminalToolExecutor: Sendable {
    let dependencies: ChatTerminalToolDependencies

    init(dependencies: ChatTerminalToolDependencies = .live) {
        self.dependencies = dependencies
    }

    @discardableResult
    func preflight(
        call: MLXChatToolCall,
        defaultWorkingDirectory: String? = nil
    ) throws -> ChatTerminalToolRequest {
        let request = try ChatTerminalToolRequest(call: call)
        let assessment = TerminalCommandSafetyPolicy.assess(command: request.command)
        if let reason = assessment.blockedReason {
            throw ChatTerminalToolError.blocked(reason)
        }
        _ = try resolveWorkingDirectory(
            request.cwd,
            defaultWorkingDirectory: defaultWorkingDirectory
        )
        return request
    }

    func execute(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> String {
        guard context.terminalApprovalGranted else {
            throw ChatTerminalToolError.approvalRequired
        }
        let request = try preflight(
            call: call,
            defaultWorkingDirectory: context.terminalDefaultWorkingDirectory
        )
        let assessment = TerminalCommandSafetyPolicy.assess(command: request.command)
        let workingDirectoryURL = try resolveWorkingDirectory(
            request.cwd,
            defaultWorkingDirectory: context.terminalDefaultWorkingDirectory
        )
        let processRequest = TerminalProcessRequest(
            command: request.command,
            currentDirectoryURL: workingDirectoryURL,
            timeout: TimeInterval(request.timeoutSeconds),
            environment: Self.scrubbedEnvironment()
        )

        let rawResult: TerminalProcessResult
        do {
            rawResult = try await dependencies.run(processRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChatTerminalToolError {
            throw error
        } catch {
            throw ChatTerminalToolError.launchFailed(error.localizedDescription)
        }

        let stdout = FileReadSecretRedactor.redact(rawResult.stdout)
        let stderr = FileReadSecretRedactor.redact(rawResult.stderr)
        let didRedact = stdout.didRedact || stderr.didRedact
        let result = TerminalProcessResult(
            stdout: stdout.text,
            stderr: stderr.text,
            exitCode: rawResult.exitCode,
            terminationSignal: rawResult.terminationSignal,
            timedOut: rawResult.timedOut,
            durationMilliseconds: rawResult.durationMilliseconds,
            outputTruncated: rawResult.outputTruncated
        )

        if result.timedOut {
            throw ChatTerminalToolError.timedOut(
                result,
                warnings: assessment.warnings,
                redacted: didRedact
            )
        }
        if result.exitCode != 0 || result.terminationSignal != nil {
            throw ChatTerminalToolError.commandFailed(
                result,
                warnings: assessment.warnings,
                redacted: didRedact
            )
        }
        return responsePayload(
            success: true,
            result: result,
            cwd: workingDirectoryURL.path,
            warnings: assessment.warnings,
            redacted: didRedact
        )
    }

    func declinedPayload() -> String {
        Self.jsonString([
            "ok": false,
            "error": "approval_declined",
            "detail":
                "The user declined this terminal command. Do not retry it unless the user asks.",
        ])
    }

    func failurePayload(error: Error) -> String {
        guard let error = error as? ChatTerminalToolError else {
            return Self.jsonString([
                "ok": false,
                "error": "execution_failed",
                "detail": error.localizedDescription,
            ])
        }
        switch error {
        case .invalidArguments(let detail):
            return Self.jsonString([
                "ok": false,
                "error": "invalid_arguments",
                "detail": detail,
            ])
        case .approvalRequired:
            return Self.jsonString([
                "ok": false,
                "error": "approval_required",
                "detail": "Every terminal call requires explicit user approval before execution.",
            ])
        case .blocked(let detail):
            return Self.jsonString([
                "ok": false,
                "error": "blocked_command",
                "detail": detail,
                "hint":
                    "Use a narrower, non-catastrophic command. Do not obfuscate or rephrase the blocked operation.",
            ])
        case .invalidWorkingDirectory(let detail):
            return Self.jsonString([
                "ok": false,
                "error": "invalid_working_directory",
                "detail": detail,
            ])
        case .launchFailed(let detail):
            return Self.jsonString([
                "ok": false,
                "error": "launch_failed",
                "detail": detail,
            ])
        case .commandFailed(let result, let warnings, let redacted):
            return responsePayload(
                success: false,
                result: result,
                cwd: nil,
                error: "command_failed",
                warnings: warnings,
                redacted: redacted
            )
        case .timedOut(let result, let warnings, let redacted):
            return responsePayload(
                success: false,
                result: result,
                cwd: nil,
                error: "timed_out",
                warnings: warnings,
                redacted: redacted
            )
        }
    }

    static func scrubbedEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedPath: String? = nil
    ) -> [String: String] {
        let path =
            resolvedPath
            ?? ShellEnvironment.resolveFromLoginShell(names: ["PATH"])["PATH"]
            ?? processEnvironment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var environment: [String: String] = [
            "PATH": path,
            "HOME": processEnvironment["HOME"] ?? NSHomeDirectory(),
            "USER": processEnvironment["USER"] ?? NSUserName(),
            "LOGNAME": processEnvironment["LOGNAME"] ?? NSUserName(),
            "SHELL": "/bin/zsh",
            "LANG": processEnvironment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": processEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
            "TERM": "dumb",
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "PAGER": "cat",
            "GIT_PAGER": "cat",
        ]
        for key in ["LC_ALL", "LC_CTYPE", "LC_MESSAGES"] {
            if let value = processEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    private func resolveWorkingDirectory(
        _ rawPath: String?,
        defaultWorkingDirectory: String?
    ) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDirectory =
            defaultWorkingDirectory.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home
        let candidate: URL
        if let rawPath {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            candidate =
                expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : defaultDirectory.appendingPathComponent(expanded, isDirectory: true)
        } else {
            candidate = defaultDirectory
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ChatTerminalToolError.invalidWorkingDirectory(
                "The requested working directory does not exist or is not a directory: \(resolved.path)"
            )
        }
        return resolved
    }

    private func responsePayload(
        success: Bool,
        result: TerminalProcessResult,
        cwd: String?,
        error: String? = nil,
        warnings: [String],
        redacted: Bool
    ) -> String {
        var payload: [String: Any] = [
            "ok": success,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "timed_out": result.timedOut,
            "duration_ms": result.durationMilliseconds,
            "output_truncated": result.outputTruncated,
            "redacted": redacted,
        ]
        if let cwd { payload["cwd"] = cwd }
        if let error { payload["error"] = error }
        if let exitCode = result.exitCode { payload["exit_code"] = Int(exitCode) }
        if let signal = result.terminationSignal {
            payload["termination_signal"] = Int(signal)
        }
        var allWarnings = warnings
        if result.outputTruncated {
            allWarnings.append("Command output was truncated to the terminal tool's size limit.")
        }
        if redacted {
            allWarnings.append("Secret-like values in command output were redacted.")
        }
        if !allWarnings.isEmpty { payload["warnings"] = allWarnings }
        return Self.jsonString(payload)
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return #"{"ok":false,"error":"serialization_failed"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct TerminalProcessRunner: Sendable {
    static let maximumStandardOutputBytes = 64 * 1_024
    static let maximumStandardErrorBytes = 32 * 1_024

    func run(_ request: TerminalProcessRequest) async throws -> TerminalProcessResult {
        let controller = TerminalProcessController(request: request)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try controller.run()
            }.value
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class TerminalProcessController: @unchecked Sendable {
    private let request: TerminalProcessRequest
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(request: TerminalProcessRequest) {
        self.request = request
    }

    func cancel() {
        let runningProcess = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        terminate(runningProcess)
    }

    func run() throws -> TerminalProcessResult {
        if lock.withLock({ cancelled }) { throw CancellationError() }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputBuffer = TerminalOutputBuffer(
            limit: TerminalProcessRunner.maximumStandardOutputBytes
        )
        let errorBuffer = TerminalOutputBuffer(
            limit: TerminalProcessRunner.maximumStandardErrorBytes
        )

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", request.command]
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(handle.availableData)
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            errorBuffer.append(handle.availableData)
        }

        lock.withLock { self.process = process }
        let start = Date()
        do {
            try process.run()
        } catch {
            stopReading(standardOutput: standardOutput, standardError: standardError)
            lock.withLock { self.process = nil }
            throw error
        }

        var timedOut = false
        let deadline = start.addingTimeInterval(request.timeout)
        while process.isRunning {
            if lock.withLock({ cancelled }) {
                terminate(process)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminate(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        lock.withLock { self.process = nil }
        stopReading(standardOutput: standardOutput, standardError: standardError)
        outputBuffer.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(standardError.fileHandleForReading.readDataToEndOfFile())

        if lock.withLock({ cancelled }) { throw CancellationError() }

        let terminationReason = process.terminationReason
        return TerminalProcessResult(
            stdout: outputBuffer.text,
            stderr: errorBuffer.text,
            exitCode: terminationReason == .exit ? process.terminationStatus : nil,
            terminationSignal: terminationReason == .uncaughtSignal
                ? process.terminationStatus : nil,
            timedOut: timedOut,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(start) * 1_000)),
            outputTruncated: outputBuffer.didTruncate || errorBuffer.didTruncate
        )
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func stopReading(standardOutput: Pipe, standardError: Pipe) {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
    }
}

private final class TerminalOutputBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            storage.append(data.prefix(remaining))
            if data.count > remaining { truncated = true }
        }
    }

    var text: String {
        lock.withLock { String(decoding: storage, as: UTF8.self) }
    }

    var didTruncate: Bool {
        lock.withLock { truncated }
    }
}
