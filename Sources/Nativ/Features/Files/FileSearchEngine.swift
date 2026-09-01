import Foundation

enum FileSearchTarget: String, Codable, Sendable {
    case content
    case files
}

enum FileSearchOutputMode: String, Codable, Sendable {
    case content
    case filesOnly = "files_only"
    case count
}

struct FileSearchRequest: Equatable, Sendable {
    let target: FileSearchTarget
    let pattern: String
    let rootURL: URL
    let fileGlob: String?
    let context: Int
}

struct FileSearchContentLine: Equatable, Sendable {
    let path: String
    let lineNumber: Int
    let text: String
    let isMatch: Bool
}

struct FileSearchRawResult: Equatable, Sendable {
    var contentLines: [FileSearchContentLine] = []
    var filePaths: [String] = []
    var scanTruncated = false
    var hadSearchErrors = false
}

enum FileSearchEngineError: Error, Equatable, Sendable {
    case executableUnavailable
    case invalidPattern
    case timedOut
    case searchFailed
}

struct RipgrepSearchEngine: Sendable {
    typealias LocateExecutable = @Sendable () throws -> URL
    typealias RunProcess = @Sendable (URL, [String]) async throws -> FileSearchProcessResult

    private let locateExecutable: LocateExecutable
    private let runProcess: RunProcess

    init(
        locateExecutable: @escaping LocateExecutable = RipgrepExecutableLocator.locate,
        runProcess: @escaping RunProcess = { executableURL, arguments in
            try await FileSearchProcessRunner().run(
                executableURL: executableURL,
                arguments: arguments
            )
        }
    ) {
        self.locateExecutable = locateExecutable
        self.runProcess = runProcess
    }

    func search(_ request: FileSearchRequest) async throws -> FileSearchRawResult {
        let executableURL: URL
        do {
            executableURL = try locateExecutable()
        } catch {
            throw FileSearchEngineError.executableUnavailable
        }

        let result: FileSearchProcessResult
        do {
            result = try await runProcess(executableURL, arguments(for: request))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FileSearchEngineError {
            throw error
        } catch {
            throw FileSearchEngineError.searchFailed
        }

        if result.terminationStatus == 2, result.stdout.isEmpty {
            let stderr = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if stderr.contains("regex parse error") || stderr.contains("error parsing regex") {
                throw FileSearchEngineError.invalidPattern
            }
            throw FileSearchEngineError.searchFailed
        }
        guard
            result.terminationStatus == 0
                || result.terminationStatus == 1
                || result.wasTerminatedForOutputLimit
                || (result.terminationStatus == 2 && !result.stdout.isEmpty)
        else {
            throw FileSearchEngineError.searchFailed
        }

        var parsed: FileSearchRawResult
        switch request.target {
        case .content:
            parsed = Self.parseContentOutput(result.stdout)
        case .files:
            parsed = Self.parseFileOutput(result.stdout)
        }
        parsed.scanTruncated = result.wasTerminatedForOutputLimit
        parsed.hadSearchErrors = result.terminationStatus == 2
        return parsed
    }

    func arguments(for request: FileSearchRequest) -> [String] {
        var arguments = ["--no-config", "--color", "never"]
        switch request.target {
        case .content:
            arguments += ["--json", "--line-number", "--sort", "path"]
            if request.context > 0 {
                arguments += ["--context", String(request.context)]
            }
            if let fileGlob = request.fileGlob, !fileGlob.isEmpty {
                arguments += ["--glob", fileGlob]
            }
            for glob in FileReadAccessPolicy.searchExclusionGlobs {
                arguments += ["--iglob", glob]
            }
            arguments += ["--", request.pattern, request.rootURL.path]
        case .files:
            arguments += ["--files", "--null", "--glob", request.pattern]
            for glob in FileReadAccessPolicy.searchExclusionGlobs {
                arguments += ["--iglob", glob]
            }
            arguments += ["--", request.rootURL.path]
        }
        return arguments
    }

    private static func parseContentOutput(_ data: Data) -> FileSearchRawResult {
        var result = FileSearchRawResult()
        for lineData in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                let event = object as? [String: Any],
                let type = event["type"] as? String,
                type == "match" || type == "context",
                let payload = event["data"] as? [String: Any],
                let path = decodedText(payload["path"]),
                let lines = decodedText(payload["lines"]),
                let lineNumber = payload["line_number"] as? Int
            else {
                continue
            }
            result.contentLines.append(
                FileSearchContentLine(
                    path: path,
                    lineNumber: lineNumber,
                    text: lines.removingOneTrailingNewline,
                    isMatch: type == "match"
                ))
        }
        return result
    }

    private static func parseFileOutput(_ data: Data) -> FileSearchRawResult {
        let paths = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return FileSearchRawResult(filePaths: paths)
    }

    private static func decodedText(_ value: Any?) -> String? {
        guard let container = value as? [String: Any] else { return nil }
        if let text = container["text"] as? String {
            return text
        }
        if let bytes = container["bytes"] as? String,
            let data = Data(base64Encoded: bytes)
        {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }
}

enum RipgrepExecutableLocator {
    static func locate() throws -> URL {
        let bundles = [Bundle.main, Bundle(for: FileSearchBundleToken.self)]
        for bundle in bundles {
            guard let resourceURL = bundle.resourceURL else { continue }
            let candidate =
                resourceURL
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent("rg", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw FileSearchEngineError.executableUnavailable
    }
}

private final class FileSearchBundleToken: NSObject {}

struct FileSearchProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let wasTerminatedForOutputLimit: Bool
}

struct FileSearchProcessRunner: Sendable {
    static let defaultTimeout: TimeInterval = 15
    static let defaultMaximumOutputBytes = 16 * 1_024 * 1_024

    var timeout = defaultTimeout
    var maximumOutputBytes = defaultMaximumOutputBytes

    func run(executableURL: URL, arguments: [String]) async throws -> FileSearchProcessResult {
        let controller = FileSearchProcessController(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try controller.run()
            }.value
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class FileSearchProcessController: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutBuffer: FileSearchDataBuffer
    private let stderrBuffer = FileSearchDataBuffer(limit: 64 * 1_024)
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var outputLimitReached = false

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) {
        self.timeout = timeout
        stdoutBuffer = FileSearchDataBuffer(limit: maximumOutputBytes)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "RIPGREP_CONFIG_PATH")
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func run() throws -> FileSearchProcessResult {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            if stdoutBuffer.append(handle.availableData) {
                lock.withLock { outputLimitReached = true }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            _ = stderrBuffer.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stopReading()
            throw FileSearchEngineError.executableUnavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            let state = lock.withLock { (cancelled, outputLimitReached) }
            if state.0 || state.1 || Date() >= deadline {
                timedOut = !state.0 && !state.1
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        stopReading()

        if stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile()) {
            lock.withLock { outputLimitReached = true }
        }
        _ = stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        if lock.withLock({ cancelled }) {
            throw CancellationError()
        }
        if timedOut {
            throw FileSearchEngineError.timedOut
        }
        return FileSearchProcessResult(
            stdout: stdoutBuffer.data,
            stderr: stderrBuffer.data,
            terminationStatus: process.terminationStatus,
            wasTerminatedForOutputLimit: lock.withLock { outputLimitReached }
        )
    }

    private func stopReading() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }
}

private final class FileSearchDataBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var data: Data {
        lock.withLock { storage }
    }

    @discardableResult
    func append(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return lock.withLock {
            let available = max(limit - storage.count, 0)
            if available > 0 {
                storage.append(data.prefix(available))
            }
            return data.count > available
        }
    }
}

extension String {
    fileprivate var removingOneTrailingNewline: String {
        if hasSuffix("\r\n") {
            return String(dropLast(2))
        }
        if hasSuffix("\n") || hasSuffix("\r") {
            return String(dropLast())
        }
        return self
    }
}
