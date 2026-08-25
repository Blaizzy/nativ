import CryptoKit
import Foundation
import NativServerKit

enum ChatFileWriteToolRegistry {
    static let writeToolName = "write_file"
    static let patchToolName = "patch"

    static let writeDefinition = MLXChatToolDefinition(
        function: MLXChatFunctionDefinition(
            name: writeToolName,
            description:
                "Create a UTF-8 text file or completely overwrite one inside the user-authorized write folder. Always replaces the entire file; use patch for targeted edits.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Target path inside the authorized write folder."),
                        "minLength": .number(1),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Complete new UTF-8 content. An empty string intentionally creates an empty file."
                        ),
                    ]),
                ]),
                "required": .array([.string("path"), .string("content")]),
            ])
        ))

    static let patchDefinition = MLXChatToolDefinition(
        function: MLXChatFunctionDefinition(
            name: patchToolName,
            description:
                "Make targeted text edits inside the user-authorized write folder. Use replace mode for one file or patch mode for a V4A multi-file patch.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("replace"), .string("patch")]),
                        "default": .string("replace"),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Replace mode target path."),
                    ]),
                    "old_string": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Replace mode text to find. Include context so it is unique."),
                    ]),
                    "new_string": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Replacement text. An empty string deletes the match."),
                    ]),
                    "patch": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Patch mode V4A patch beginning with *** Begin Patch."),
                    ]),
                    "replace_all": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                    ]),
                ]),
            ])
        ))

    static let definitions = [writeDefinition, patchDefinition]
    static let toolNames = [writeToolName, patchToolName]
}

struct ChatFileWriteToolDependencies: Sendable {
    typealias Read = @Sendable (URL) async throws -> SafeLocalFileSnapshot
    typealias Write = @Sendable (Data, URL, Bool) async throws -> FileReadFileStamp
    typealias Delete = @Sendable (URL) async throws -> Void
    typealias Move = @Sendable (URL, URL) async throws -> Void
    typealias Validate = @Sendable (URL, String?, String?) async -> [String]

    let read: Read
    let write: Write
    let delete: Delete
    let move: Move
    let validate: Validate

    static let live: Self = {
        let reader = SafeLocalFileReader()
        let writer = SafeLocalFileWriter()
        let validator = FileSyntaxValidator()
        return Self(
            read: { try await reader.read(url: $0) },
            write: { data, url, overwrite in
                try writer.write(data: data, to: url, overwrite: overwrite)
            },
            delete: { try writer.delete(url: $0) },
            move: { try writer.move(from: $0, to: $1) },
            validate: { await validator.newIssues(at: $0, before: $1, after: $2) }
        )
    }()
}

enum ChatFileWriteToolError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case notConfigured
    case outsideAllowedRoot
    case sensitivePath
    case binaryDocument
    case approvalRequired
    case fileNotFound
    case fileAlreadyExists
    case unsupportedFileType
    case contentTooLarge(Int)
    case readDumpRejected
    case oldStringNotFound(hint: String?)
    case ambiguousMatch(Int)
    case invalidPatch(String)
    case permissionDenied
    case unexpectedFailure

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .notConfigured: "file_write_not_configured"
        case .outsideAllowedRoot: "outside_allowed_root"
        case .sensitivePath: "sensitive_path"
        case .binaryDocument: "binary_document"
        case .approvalRequired: "approval_required"
        case .fileNotFound: "file_not_found"
        case .fileAlreadyExists: "file_already_exists"
        case .unsupportedFileType: "unsupported_file_type"
        case .contentTooLarge: "content_too_large"
        case .readDumpRejected: "read_dump_rejected"
        case .oldStringNotFound: "old_string_not_found"
        case .ambiguousMatch: "ambiguous_match"
        case .invalidPatch: "invalid_patch"
        case .permissionDenied: "permission_denied"
        case .unexpectedFailure: "unexpected_failure"
        }
    }

    var message: String {
        switch self {
        case .invalidArguments(let message), .invalidPatch(let message): message
        case .notConfigured: "File Write has no authorized folder."
        case .outsideAllowedRoot: "The requested path is outside the authorized write folder."
        case .sensitivePath: "Nativ will not modify this sensitive system or credential path."
        case .binaryDocument: "Plain-text file tools cannot modify this binary document format."
        case .approvalRequired:
            "This protected file requires human confirmation before it can be changed."
        case .fileNotFound: "The target file was not found."
        case .fileAlreadyExists:
            "The target already exists and this operation does not allow overwriting it."
        case .unsupportedFileType: "Only regular files can be modified."
        case .contentTooLarge(let maximum):
            "The new content exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(maximum), countStyle: .file)) safety limit."
        case .readDumpRejected:
            "The proposed content looks like numbered read_file output or an unchanged-read stub."
        case .oldStringNotFound:
            "old_string was not found, including with whitespace-tolerant matching."
        case .ambiguousMatch(let count):
            "old_string matched \(count) locations. Include more context or set replace_all=true."
        case .permissionDenied: "Nativ does not have permission to modify this path."
        case .unexpectedFailure: "The file operation failed unexpectedly."
        }
    }

    var hint: String? {
        switch self {
        case .notConfigured:
            "Choose an authorized folder in Extensions → Tools → File Write."
        case .binaryDocument:
            "Use a document-specific editor rather than replacing the file with plain text."
        case .readDumpRejected:
            "Pass the original file content without LINE| prefixes or dedup response metadata."
        case .oldStringNotFound(let hint): hint
        case .approvalRequired:
            "Confirm the pending File Write request in the chat."
        default: nil
        }
    }
}

enum ChatFileWriteApprovalPolicy {
    static func requiresApproval(call: MLXChatToolCall, rootPath: String?) -> Bool {
        guard let name = call.function?.name,
            let arguments = call.function?.arguments,
            let policy = try? FileWriteAccessPolicy(rootPath: rootPath)
        else { return false }
        do {
            let paths: [String]
            switch name {
            case ChatFileWriteToolRegistry.writeToolName:
                paths = [
                    try JSONDecoder().decode(WriteFileArguments.self, from: Data(arguments.utf8))
                        .path
                ]
            case ChatFileWriteToolRegistry.patchToolName:
                let decoded = try JSONDecoder().decode(
                    PatchFileArguments.self, from: Data(arguments.utf8))
                if decoded.mode == "patch" {
                    paths = try V4AFilePatchParser.parse(decoded.patch ?? "").flatMap(\.paths)
                } else {
                    paths = decoded.path.map { [$0] } ?? []
                }
            default:
                return false
            }
            return try paths.contains {
                try policy.resolve(path: $0).approvalRequirement != nil
            }
        } catch {
            return false
        }
    }
}

struct ChatFileWriteToolExecutor {
    func execute(call: MLXChatToolCall, context: ChatToolExecutionContext) async throws -> String {
        switch call.function?.name {
        case ChatFileWriteToolRegistry.writeToolName:
            return try await executeWrite(call: call, context: context)
        case ChatFileWriteToolRegistry.patchToolName:
            return try await executePatch(call: call, context: context)
        default:
            throw ChatFileWriteToolError.invalidArguments("Unsupported File Write operation.")
        }
    }

    func failurePayload(error: Error) -> String {
        let mapped = Self.mapped(error)
        return
            (try? Self.encoded(
                FileWriteFailurePayload(
                    ok: false,
                    error: FileWriteFailure(
                        code: mapped.code, message: mapped.message, hint: mapped.hint)
                )))
            ?? #"{"ok":false,"error":{"code":"unexpected_failure","message":"The file operation failed unexpectedly."}}"#
    }

    func declinedPayload() -> String {
        #"{"ok":false,"error":{"code":"user_declined","message":"The user declined to modify this protected file."}}"#
    }

    private func executeWrite(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> String {
        let arguments: WriteFileArguments = try Self.decode(call)
        guard !arguments.path.isEmpty else {
            throw ChatFileWriteToolError.invalidArguments("path must not be empty.")
        }
        try Self.rejectReadDump(arguments.content)
        let policy = try Self.policy(context)
        let target = try Self.resolve(arguments.path, policy: policy)
        try Self.requireApprovalIfNeeded(target, context: context)

        let locks = await context.fileMutationState.locks(for: [target.url.path])
        await Self.acquire(locks)
        do {
            let beforeSnapshot = try await Self.optionalSnapshot(
                target.url,
                dependencies: context.fileWriteToolDependencies
            )
            let beforeText = try beforeSnapshot.map(Self.text)
            let warning = await context.fileMutationState.stalenessWarning(
                path: target.url.path,
                currentStamp: beforeSnapshot?.stamp,
                runID: context.fileOperationRunID
            )
            let stamp = try await context.fileWriteToolDependencies.write(
                Data(arguments.content.utf8), target.url, true
            )
            let issues = await context.fileWriteToolDependencies.validate(
                target.url, beforeText, arguments.content
            )
            await Self.finishMutation(
                path: target.url.path,
                stamp: stamp,
                context: context
            )
            await Self.release(locks)
            return try Self.encoded(
                FileWriteSuccessPayload(
                    resolvedPath: target.url.path,
                    filesModified: [target.displayPath],
                    warning: warning,
                    hint: issues.isEmpty
                        ? nil : "Review the new syntax errors reported in lint_errors.",
                    diff: FileUnifiedDiff.render(
                        path: target.displayPath,
                        before: beforeText,
                        after: arguments.content
                    ),
                    verified: true,
                    sha256: Self.hash(arguments.content),
                    lintErrors: issues
                ))
        } catch {
            await Self.release(locks)
            throw error
        }
    }

    private func executePatch(
        call: MLXChatToolCall,
        context: ChatToolExecutionContext
    ) async throws -> String {
        let arguments: PatchFileArguments = try Self.decode(call)
        switch arguments.mode ?? "replace" {
        case "replace":
            return try await executeReplacement(arguments, context: context)
        case "patch":
            guard let patch = arguments.patch else {
                throw ChatFileWriteToolError.invalidArguments("patch is required in patch mode.")
            }
            return try await executeV4APatch(patch, context: context)
        default:
            throw ChatFileWriteToolError.invalidArguments("mode must be replace or patch.")
        }
    }

    private func executeReplacement(
        _ arguments: PatchFileArguments,
        context: ChatToolExecutionContext
    ) async throws -> String {
        guard let path = arguments.path, !path.isEmpty,
            let oldText = arguments.oldString,
            let newText = arguments.newString
        else {
            throw ChatFileWriteToolError.invalidArguments(
                "Replace mode requires path, old_string, and new_string."
            )
        }
        guard !oldText.isEmpty else {
            throw ChatFileWriteToolError.invalidArguments("old_string must not be empty.")
        }
        try Self.rejectReadDump(newText)
        let policy = try Self.policy(context)
        let target = try Self.resolve(path, policy: policy)
        try Self.requireApprovalIfNeeded(target, context: context)

        let locks = await context.fileMutationState.locks(for: [target.url.path])
        await Self.acquire(locks)
        do {
            let snapshot = try await context.fileWriteToolDependencies.read(target.url)
            let before = try Self.text(snapshot)
            let after: String
            do {
                after = try FuzzyFileTextReplacer.replacing(
                    in: before,
                    oldText: oldText,
                    newText: newText,
                    replaceAll: arguments.replaceAll ?? false
                )
            } catch FileEditEngineError.oldStringNotFound {
                let failures = await context.fileMutationState.recordReplacementFailure(
                    path: target.url.path
                )
                let hint =
                    failures >= 2
                    ? "Re-read the file before retrying, or use write_file if a complete replacement is intended."
                    : "Include more surrounding context from the latest file content."
                throw ChatFileWriteToolError.oldStringNotFound(hint: hint)
            }
            let warning = await context.fileMutationState.stalenessWarning(
                path: target.url.path,
                currentStamp: snapshot.stamp,
                runID: context.fileOperationRunID
            )
            let stamp = try await context.fileWriteToolDependencies.write(
                Data(after.utf8), target.url, true
            )
            let issues = await context.fileWriteToolDependencies.validate(target.url, before, after)
            await context.fileMutationState.resetReplacementFailures(paths: [target.url.path])
            await Self.finishMutation(path: target.url.path, stamp: stamp, context: context)
            await Self.release(locks)
            return try Self.encoded(
                FileWriteSuccessPayload(
                    resolvedPath: target.url.path,
                    filesModified: [target.displayPath],
                    warning: warning,
                    hint: issues.isEmpty
                        ? nil : "Review the new syntax errors reported in lint_errors.",
                    diff: FileUnifiedDiff.render(
                        path: target.displayPath, before: before, after: after),
                    verified: true,
                    sha256: Self.hash(after),
                    lintErrors: issues
                ))
        } catch {
            await Self.release(locks)
            throw error
        }
    }

    private func executeV4APatch(
        _ patch: String,
        context: ChatToolExecutionContext
    ) async throws -> String {
        let operations: [FilePatchOperation]
        do {
            operations = try V4AFilePatchParser.parse(patch)
        } catch let error as FileEditEngineError {
            throw Self.mapped(error)
        }
        let policy = try Self.policy(context)
        let resolvedOperations = try operations.map {
            try ResolvedPatchOperation($0, policy: policy)
        }
        let allPaths = resolvedOperations.flatMap(\.absolutePaths)
        guard Set(allPaths).count == allPaths.count else {
            throw ChatFileWriteToolError.invalidPatch(
                "A multi-file patch may touch each path only once. Combine hunks for the same file."
            )
        }
        for operation in resolvedOperations {
            for target in operation.targets {
                try Self.requireApprovalIfNeeded(target, context: context)
            }
        }

        let locks = await context.fileMutationState.locks(for: allPaths)
        await Self.acquire(locks)
        do {
            var plans: [PlannedPatchMutation] = []
            for operation in resolvedOperations {
                plans.append(
                    try await plan(
                        operation,
                        context: context
                    ))
            }

            var warnings: [String] = []
            var diffs: [String] = []
            var modified: [String] = []
            var lintErrors: [String] = []
            var finalHash: String?

            for plan in plans {
                if let warning = await context.fileMutationState.stalenessWarning(
                    path: plan.primary.url.path,
                    currentStamp: plan.beforeStamp,
                    runID: context.fileOperationRunID
                ) {
                    warnings.append(warning)
                }
                let result = try await apply(plan, context: context)
                modified.append(contentsOf: result.modifiedPaths)
                diffs.append(result.diff)
                lintErrors.append(contentsOf: result.lintErrors)
                finalHash = result.hash ?? finalHash
            }
            await context.fileMutationState.resetReplacementFailures(paths: allPaths)
            await Self.release(locks)
            return try Self.encoded(
                FileWriteSuccessPayload(
                    resolvedPath: plans.first?.primary.url.path ?? policy.rootURL.path,
                    filesModified: modified,
                    warning: warnings.isEmpty ? nil : Array(Set(warnings)).joined(separator: " "),
                    hint: lintErrors.isEmpty
                        ? nil : "Review the new syntax errors reported in lint_errors.",
                    diff: diffs.joined(separator: "\n\n"),
                    verified: true,
                    sha256: plans.count == 1 ? finalHash : nil,
                    lintErrors: lintErrors
                ))
        } catch {
            await Self.release(locks)
            throw error
        }
    }

    private func plan(
        _ operation: ResolvedPatchOperation,
        context: ChatToolExecutionContext
    ) async throws -> PlannedPatchMutation {
        switch operation {
        case .add(let target, let content):
            try Self.rejectReadDump(content)
            guard
                try await Self.optionalSnapshot(
                    target.url,
                    dependencies: context.fileWriteToolDependencies
                ) == nil
            else {
                throw ChatFileWriteToolError.fileAlreadyExists
            }
            return .write(target: target, before: nil, after: content, overwrite: false)
        case .update(let target, let replacements, let moveTo):
            let snapshot = try await context.fileWriteToolDependencies.read(target.url)
            let before = try Self.text(snapshot)
            var after = before
            for replacement in replacements {
                try Self.rejectReadDump(replacement.newText)
                do {
                    after = try FuzzyFileTextReplacer.replacing(
                        in: after,
                        oldText: replacement.oldText,
                        newText: replacement.newText,
                        replaceAll: false
                    )
                } catch {
                    throw Self.mapped(error)
                }
            }
            if let moveTo {
                guard
                    try await Self.optionalSnapshot(
                        moveTo.url,
                        dependencies: context.fileWriteToolDependencies
                    ) == nil
                else {
                    throw ChatFileWriteToolError.fileAlreadyExists
                }
                return .updateAndMove(
                    source: target,
                    destination: moveTo,
                    before: before,
                    after: after,
                    stamp: snapshot.stamp
                )
            }
            return .write(
                target: target,
                before: before,
                after: after,
                overwrite: true,
                beforeStamp: snapshot.stamp
            )
        case .delete(let target):
            let snapshot = try await context.fileWriteToolDependencies.read(target.url)
            return .delete(target: target, before: try Self.text(snapshot), stamp: snapshot.stamp)
        case .move(let source, let destination):
            let snapshot = try await context.fileWriteToolDependencies.read(source.url)
            guard
                try await Self.optionalSnapshot(
                    destination.url,
                    dependencies: context.fileWriteToolDependencies
                ) == nil
            else {
                throw ChatFileWriteToolError.fileAlreadyExists
            }
            return .move(
                source: source,
                destination: destination,
                content: try Self.text(snapshot),
                stamp: snapshot.stamp
            )
        }
    }

    private func apply(
        _ plan: PlannedPatchMutation,
        context: ChatToolExecutionContext
    ) async throws -> AppliedPatchMutation {
        switch plan {
        case .write(let target, let before, let after, let overwrite, _):
            let stamp = try await context.fileWriteToolDependencies.write(
                Data(after.utf8), target.url, overwrite
            )
            let issues = await context.fileWriteToolDependencies.validate(target.url, before, after)
            await Self.finishMutation(path: target.url.path, stamp: stamp, context: context)
            return AppliedPatchMutation(
                modifiedPaths: [target.displayPath],
                diff: FileUnifiedDiff.render(
                    path: target.displayPath, before: before, after: after),
                lintErrors: issues,
                hash: Self.hash(after)
            )
        case .delete(let target, let before, _):
            try await context.fileWriteToolDependencies.delete(target.url)
            await Self.finishMutation(path: target.url.path, stamp: nil, context: context)
            return AppliedPatchMutation(
                modifiedPaths: [target.displayPath],
                diff: FileUnifiedDiff.render(path: target.displayPath, before: before, after: nil),
                lintErrors: [],
                hash: nil
            )
        case .move(let source, let destination, let content, let stamp):
            try await context.fileWriteToolDependencies.move(source.url, destination.url)
            await Self.finishMutation(path: source.url.path, stamp: nil, context: context)
            await Self.finishMutation(path: destination.url.path, stamp: stamp, context: context)
            return AppliedPatchMutation(
                modifiedPaths: [source.displayPath, destination.displayPath],
                diff: FileUnifiedDiff.render(path: source.displayPath, before: content, after: nil)
                    + "\n\n"
                    + FileUnifiedDiff.render(
                        path: destination.displayPath, before: nil, after: content),
                lintErrors: [],
                hash: Self.hash(content)
            )
        case .updateAndMove(let source, let destination, let before, let after, _):
            let stamp = try await context.fileWriteToolDependencies.write(
                Data(after.utf8), source.url, true
            )
            try await context.fileWriteToolDependencies.move(source.url, destination.url)
            let issues = await context.fileWriteToolDependencies.validate(
                destination.url, before, after
            )
            await Self.finishMutation(path: source.url.path, stamp: nil, context: context)
            await Self.finishMutation(path: destination.url.path, stamp: stamp, context: context)
            return AppliedPatchMutation(
                modifiedPaths: [source.displayPath, destination.displayPath],
                diff: FileUnifiedDiff.render(path: source.displayPath, before: before, after: nil)
                    + "\n\n"
                    + FileUnifiedDiff.render(
                        path: destination.displayPath, before: nil, after: after),
                lintErrors: issues,
                hash: Self.hash(after)
            )
        }
    }

    private static func decode<T: Decodable>(_ call: MLXChatToolCall) throws -> T {
        guard let arguments = call.function?.arguments else {
            throw ChatFileWriteToolError.invalidArguments("Tool arguments are missing.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(arguments.utf8))
        } catch {
            throw ChatFileWriteToolError.invalidArguments("Tool arguments do not match the schema.")
        }
    }

    private static func policy(_ context: ChatToolExecutionContext) throws -> FileWriteAccessPolicy
    {
        do {
            return try FileWriteAccessPolicy(rootPath: context.fileWriteRootPath)
        } catch {
            throw mapped(error)
        }
    }

    private static func resolve(
        _ path: String,
        policy: FileWriteAccessPolicy
    ) throws -> ResolvedFileWritePath {
        do {
            return try policy.resolve(path: path)
        } catch {
            throw mapped(error)
        }
    }

    private static func requireApprovalIfNeeded(
        _ target: ResolvedFileWritePath,
        context: ChatToolExecutionContext
    ) throws {
        if target.approvalRequirement != nil, !context.fileWriteApprovalGranted {
            throw ChatFileWriteToolError.approvalRequired
        }
    }

    private static func optionalSnapshot(
        _ url: URL,
        dependencies: ChatFileWriteToolDependencies
    ) async throws -> SafeLocalFileSnapshot? {
        do {
            return try await dependencies.read(url)
        } catch SafeLocalFileReaderError.notFound {
            return nil
        } catch {
            throw mapped(error)
        }
    }

    private static func text(_ snapshot: SafeLocalFileSnapshot) throws -> String {
        guard !snapshot.data.prefix(8_192).contains(0),
            let text = String(data: snapshot.data, encoding: .utf8)
        else {
            throw ChatFileWriteToolError.unsupportedFileType
        }
        return text
    }

    private static func rejectReadDump(_ content: String) throws {
        if let data = content.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if object["dedup"] as? Bool == true,
                object["content_returned"] as? Bool == false
            {
                throw ChatFileWriteToolError.readDumpRejected
            }
            if let nestedContent = object["content"] as? String,
                looksLikeNumberedDump(nestedContent)
            {
                throw ChatFileWriteToolError.readDumpRejected
            }
        }
        if looksLikeNumberedDump(content) {
            throw ChatFileWriteToolError.readDumpRejected
        }
    }

    private static func looksLikeNumberedDump(_ content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        let expression = try? NSRegularExpression(pattern: #"^\d+\|"#)
        let numbered = lines.filter { line in
            let range = NSRange(line.startIndex ..< line.endIndex, in: line)
            return expression?.firstMatch(in: line, range: range) != nil
        }.count
        return numbered >= 2 && Double(numbered) / Double(lines.count) >= 0.8
    }

    private static func finishMutation(
        path: String,
        stamp: FileReadFileStamp?,
        context: ChatToolExecutionContext
    ) async {
        await context.fileMutationState.recordWrite(
            path: path,
            stamp: stamp,
            runID: context.fileOperationRunID
        )
        await context.fileReadTracker?.invalidate(path: path)
    }

    private static func acquire(_ locks: [FilePathMutationLock]) async {
        for lock in locks { await lock.acquire() }
    }

    private static func release(_ locks: [FilePathMutationLock]) async {
        for lock in locks.reversed() { await lock.release() }
    }

    private static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func mapped(_ error: Error) -> ChatFileWriteToolError {
        if let error = error as? ChatFileWriteToolError { return error }
        if let error = error as? FileWriteAccessError {
            return switch error {
            case .notConfigured: .notConfigured
            case .invalidPath: .invalidArguments("The target path is invalid.")
            case .outsideAllowedRoot: .outsideAllowedRoot
            case .sensitivePath: .sensitivePath
            case .binaryDocument: .binaryDocument
            }
        }
        if let error = error as? SafeLocalFileReaderError {
            return switch error {
            case .notFound: .fileNotFound
            case .permissionDenied: .permissionDenied
            case .unsupportedFileType: .unsupportedFileType
            case .fileTooLarge(let maximum): .contentTooLarge(maximum)
            case .changedDuringRead, .ioFailure: .unexpectedFailure
            }
        }
        if let error = error as? SafeLocalFileWriterError {
            return switch error {
            case .notFound: .fileNotFound
            case .alreadyExists: .fileAlreadyExists
            case .permissionDenied: .permissionDenied
            case .unsupportedFileType: .unsupportedFileType
            case .contentTooLarge(let maximum): .contentTooLarge(maximum)
            case .ioFailure: .unexpectedFailure
            }
        }
        if let error = error as? FileEditEngineError {
            return switch error {
            case .invalidPatch(let message): .invalidPatch(message)
            case .oldStringNotFound: .oldStringNotFound(hint: nil)
            case .ambiguousMatch(let count): .ambiguousMatch(count)
            }
        }
        return .unexpectedFailure
    }

    private static func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct WriteFileArguments: Decodable {
    let path: String
    let content: String
}

private struct PatchFileArguments: Decodable {
    let mode: String?
    let path: String?
    let oldString: String?
    let newString: String?
    let patch: String?
    let replaceAll: Bool?

    enum CodingKeys: String, CodingKey {
        case mode, path, patch
        case oldString = "old_string"
        case newString = "new_string"
        case replaceAll = "replace_all"
    }
}

private enum ResolvedPatchOperation {
    case add(ResolvedFileWritePath, String)
    case update(ResolvedFileWritePath, [FileTextReplacement], ResolvedFileWritePath?)
    case delete(ResolvedFileWritePath)
    case move(ResolvedFileWritePath, ResolvedFileWritePath)

    init(_ operation: FilePatchOperation, policy: FileWriteAccessPolicy) throws {
        switch operation {
        case .add(let path, let content):
            self = .add(try policy.resolve(path: path), content)
        case .update(let path, let replacements, let moveTo):
            self = .update(
                try policy.resolve(path: path),
                replacements,
                try moveTo.map { try policy.resolve(path: $0) }
            )
        case .delete(let path):
            self = .delete(try policy.resolve(path: path))
        case .move(let path, let destination):
            self = .move(
                try policy.resolve(path: path),
                try policy.resolve(path: destination)
            )
        }
    }

    var targets: [ResolvedFileWritePath] {
        switch self {
        case .add(let target, _), .delete(let target): [target]
        case .update(let target, _, let destination): [target] + (destination.map { [$0] } ?? [])
        case .move(let source, let destination): [source, destination]
        }
    }

    var absolutePaths: [String] { targets.map(\.url.path) }
}

private enum PlannedPatchMutation {
    case write(
        target: ResolvedFileWritePath,
        before: String?,
        after: String,
        overwrite: Bool,
        beforeStamp: FileReadFileStamp? = nil
    )
    case delete(target: ResolvedFileWritePath, before: String, stamp: FileReadFileStamp)
    case move(
        source: ResolvedFileWritePath,
        destination: ResolvedFileWritePath,
        content: String,
        stamp: FileReadFileStamp
    )
    case updateAndMove(
        source: ResolvedFileWritePath,
        destination: ResolvedFileWritePath,
        before: String,
        after: String,
        stamp: FileReadFileStamp
    )

    var primary: ResolvedFileWritePath {
        switch self {
        case .write(let target, _, _, _, _), .delete(let target, _, _): target
        case .move(let source, _, _, _), .updateAndMove(let source, _, _, _, _): source
        }
    }

    var beforeStamp: FileReadFileStamp? {
        switch self {
        case .write(_, _, _, _, let stamp): stamp
        case .delete(_, _, let stamp), .move(_, _, _, let stamp),
            .updateAndMove(_, _, _, _, let stamp):
            stamp
        }
    }
}

private struct AppliedPatchMutation {
    let modifiedPaths: [String]
    let diff: String
    let lintErrors: [String]
    let hash: String?
}

private struct FileWriteSuccessPayload: Encodable {
    let ok = true
    let resolvedPath: String
    let filesModified: [String]
    let warning: String?
    let hint: String?
    let diff: String
    let verified: Bool
    let sha256: String?
    let lintErrors: [String]

    enum CodingKeys: String, CodingKey {
        case ok, diff, verified, sha256
        case resolvedPath = "resolved_path"
        case filesModified = "files_modified"
        case warning = "_warning"
        case hint = "_hint"
        case lintErrors = "lint_errors"
    }
}

private struct FileWriteFailurePayload: Encodable {
    let ok: Bool
    let error: FileWriteFailure
}

private struct FileWriteFailure: Encodable {
    let code: String
    let message: String
    let hint: String?
}
