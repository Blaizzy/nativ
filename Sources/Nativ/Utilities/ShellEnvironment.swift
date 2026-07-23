import Foundation

/// Reads environment variables from the user's login shell.
///
/// GUI apps on macOS inherit their environment from launchd, which knows
/// nothing about exports in shell startup files (`.zshrc`, `.zprofile`, …).
/// Spawning the shell as a login + interactive shell sources those files,
/// letting the app discover variables users commonly export there. The same
/// approach is used by VS Code and JetBrains IDEs.
enum ShellEnvironment {
    /// Segment separating shell-startup noise from the `env` output.
    static let marker = "__NATIV_ENV__"

    /// Resolves `names` by running the user's login shell once. Returns an
    /// empty dictionary on any failure (missing shell, timeout, …).
    static func resolveFromLoginShell(
        names: [String],
        timeout: TimeInterval = 3
    ) -> [String: String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            return [:]
        }
        // NUL-separated output survives arbitrary values; the marker keeps
        // shell-startup noise (prompts, banners) out of the parsed region.
        return environment(
            names: Set(names),
            executablePath: shellPath,
            arguments: ["-l", "-i", "-c", "printf '\\0\(marker)\\0'; /usr/bin/env -0"],
            timeout: timeout
        )
    }

    /// Runs an executable and parses NUL-separated `KEY=VALUE` entries from
    /// its stdout, limited to `names`. Internal (not private) for testing.
    static func environment(
        names: Set<String>,
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> [String: String] {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let output = NSMutableData()
        let outputLock = NSLock()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            output.append(chunk)
            outputLock.unlock()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            return [:]
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
        }

        // Drain whatever remains in the pipe after the handler stops.
        stdout.fileHandleForReading.readabilityHandler = nil
        let remainder = stdout.fileHandleForReading.readDataToEndOfFile()
        outputLock.lock()
        output.append(remainder)
        let data = output as Data
        outputLock.unlock()

        return parseEnvironment(String(decoding: data, as: UTF8.self), names: names)
    }

    /// Parses NUL-separated `KEY=VALUE` entries, ignoring everything before
    /// `marker` and any segment without a key. Later entries win.
    static func parseEnvironment(_ output: String, names: Set<String>) -> [String: String] {
        var segments = output.components(separatedBy: "\0")
        if let markerIndex = segments.firstIndex(of: marker) {
            segments = Array(segments[(markerIndex + 1)...])
        }
        var result: [String: String] = [:]
        for segment in segments {
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let key = String(segment[..<separator])
            guard names.contains(key) else { continue }
            result[key] = String(segment[segment.index(after: separator)...])
        }
        return result
    }
}
