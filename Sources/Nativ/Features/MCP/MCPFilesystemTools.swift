import Foundation
import NativServerKit

/// The bundled filesystem server supplies schemas, but its file operations use
/// Nativ's policies and no-follow I/O. Argument checks followed by a subprocess
/// call cannot enforce the blocklist when a path changes during startup or I/O.
@MainActor
enum MCPFilesystemTools {
    enum Tool: String, CaseIterable {
        case readFile = "read_file"
        case readTextFile = "read_text_file"
        case readMediaFile = "read_media_file"
        case readMultipleFiles = "read_multiple_files"
        case writeFile = "write_file"
        case editFile = "edit_file"
        case createDirectory = "create_directory"
        case listDirectory = "list_directory"
        case listDirectoryWithSizes = "list_directory_with_sizes"
        case directoryTree = "directory_tree"
        case moveFile = "move_file"
        case searchFiles = "search_files"
        case getFileInfo = "get_file_info"
        case listAllowedDirectories = "list_allowed_directories"

        var writesFiles: Bool {
            [.writeFile, .editFile, .createDirectory, .moveFile].contains(self)
        }
    }

    private static let maximumEntries = 10_000
    private static let maximumResultCharacters = 100_000

    static func requiresApproval(
        tool: Tool, argumentsJSON: String?, rootPath: String?
    ) -> Bool {
        guard tool.writesFiles,
            let arguments = try? arguments(argumentsJSON),
            !(tool == .editFile && arguments["dryRun"] as? Bool == true),
            let policy = try? FileWriteAccessPolicy(rootPath: rootPath)
        else { return false }
        let keys = tool == .moveFile ? ["source", "destination"] : ["path"]
        return keys.contains { key in
            guard let path = arguments[key] as? String,
                let target = try? policy.resolve(path: path)
            else { return false }
            return target.approvalRequirement != nil
        }
    }

    static func execute(
        tool: Tool,
        argumentsJSON: String?,
        root: URL,
        approvalGranted: Bool,
        validateScope: () throws -> Void
    ) async throws -> String {
        let arguments = try arguments(argumentsJSON)
        let readPolicy = try FileReadAccessPolicy(rootPath: root.path)
        let directories = SafeLocalDirectoryReader()
        let reader = SafeLocalFileReader()
        let writer = SafeLocalFileWriter()

        func readPath(_ path: String) throws -> URL {
            try readPolicy.resolve(path: path).url
        }
        func writePath(_ path: String) throws -> URL {
            // A writable folder does not authorize access to protected stores.
            _ = try readPolicy.resolve(path: path)
            let target = try FileWriteAccessPolicy(rootPath: root.path).resolve(path: path)
            guard target.approvalRequirement == nil || approvalGranted else {
                throw MCPClientError.toolFailed(
                    "This protected file requires confirmation before it can be changed."
                )
            }
            return target.url
        }
        func path(_ key: String = "path") throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw MCPClientError.toolFailed("\(key) must be a nonempty path.")
            }
            return value
        }
        func text(at url: URL) async throws -> String {
            let snapshot = try await reader.read(url: url)
            guard !FileReadContentPolicy.binaryExtensions.contains(url.pathExtension.lowercased()),
                !FileReadContentPolicy.unsupportedDocumentExtensions.contains(
                    url.pathExtension.lowercased()),
                !FileReadContentPolicy.hasBinaryMagic(snapshot.data),
                let text = FileReadContentPolicy.decodeText(snapshot.data)
            else {
                throw MCPClientError.toolFailed("The file is not a supported text file.")
            }
            return text
        }
        func visibleEntries(at url: URL) throws -> [SafeLocalDirectoryReader.Entry] {
            try directories.contents(of: url).filter {
                (try? readPolicy.resolve(path: url.appendingPathComponent($0.name).path)) != nil
            }
        }

        try validateScope()
        let result: String
        switch tool {
        case .readFile, .readTextFile:
            let value = FileReadSecretRedactor.redact(try await text(at: readPath(path()))).text
            let head = try lineLimit("head", in: arguments)
            let tail = try lineLimit("tail", in: arguments)
            guard head == nil || tail == nil else {
                throw MCPClientError.toolFailed("Specify head or tail, not both.")
            }
            let lines = value.components(separatedBy: "\n")
            let selected =
                head.map { lines.prefix($0).joined(separator: "\n") }
                ?? tail.map { lines.suffix($0).joined(separator: "\n") } ?? value
            result = selected

        case .readMultipleFiles:
            guard let paths = arguments["paths"] as? [String], !paths.isEmpty,
                paths.count <= 100
            else {
                throw MCPClientError.toolFailed("paths must contain 1 to 100 file paths.")
            }
            var values: [String] = []
            var remaining = maximumResultCharacters
            for path in paths {
                try Task.checkCancellation()
                try validateScope()
                let value = FileReadSecretRedactor.redact(try await text(at: readPath(path))).text
                let section = "\(path):\n\(value)"
                values.append(String(section.prefix(remaining)))
                remaining -= min(remaining, section.count)
                if remaining == 0 { break }
            }
            result = values.joined(separator: "\n---\n")

        case .readMediaFile:
            let url = try readPath(path())
            let types = [
                "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp",
                "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "flac": "audio/flac",
            ]
            guard let type = types[url.pathExtension.lowercased()] else {
                throw MCPClientError.toolFailed("Unsupported image or audio file type.")
            }
            let snapshot = try await SafeLocalFileReader(maximumBytes: 64_000).read(url: url)
            result = try json(["mimeType": type, "data": snapshot.data.base64EncodedString()])

        case .writeFile:
            guard let content = arguments["content"] as? String else {
                throw MCPClientError.toolFailed("content must be a string.")
            }
            let url = try writePath(path())
            try validateScope()
            _ = try writer.write(data: Data(content.utf8), to: url)
            result = "Successfully wrote to \(readPolicy.displayPath(for: url))"

        case .editFile:
            let dryRun = arguments["dryRun"] as? Bool == true
            let url = try dryRun ? readPath(path()) : writePath(path())
            guard let edits = arguments["edits"] as? [[String: String]], !edits.isEmpty else {
                throw MCPClientError.toolFailed("edits must contain oldText/newText replacements.")
            }
            let before = try await text(at: url)
            var after = before
            for edit in edits {
                guard let old = edit["oldText"], !old.isEmpty, let new = edit["newText"] else {
                    throw MCPClientError.toolFailed(
                        "An edit did not match the file's current text.")
                }
                if let range = after.range(of: old) {
                    after.replaceSubrange(range, with: new)
                } else {
                    after = try FuzzyFileTextReplacer.replacing(
                        in: after, oldText: old, newText: new, replaceAll: false
                    )
                }
            }
            try validateScope()
            if !dryRun { _ = try writer.write(data: Data(after.utf8), to: url) }
            result =
                FileReadSecretRedactor.redact(
                    FileUnifiedDiff.renderWithMetadata(
                        path: readPolicy.displayPath(for: url), before: before, after: after
                    ).content
                ).text

        case .createDirectory:
            let url = try writePath(path())
            try validateScope()
            try writer.createDirectory(at: url)
            result = "Successfully created directory \(readPolicy.displayPath(for: url))"

        case .moveFile:
            let source = try writePath(path("source"))
            let destination = try writePath(path("destination"))
            try validateScope()
            try writer.move(from: source, to: destination)
            result =
                "Successfully moved \(readPolicy.displayPath(for: source)) to \(readPolicy.displayPath(for: destination))"

        case .listDirectory, .listDirectoryWithSizes:
            let url = try readPath(path())
            var entries = try visibleEntries(at: url)
            if tool == .listDirectoryWithSizes, arguments["sortBy"] as? String == "size" {
                entries.sort { $0.size > $1.size }
            }
            result = entries.map {
                let size =
                    tool == .listDirectoryWithSizes && !$0.isDirectory ? " (\($0.size) bytes)" : ""
                return "[\($0.isDirectory ? "DIR" : "FILE")] \($0.name)\(size)"
            }.joined(separator: "\n")

        case .directoryTree, .searchFiles:
            let url = try readPath(path())
            let excludes = arguments["excludePatterns"] as? [String] ?? []
            let pattern = arguments["pattern"] as? String
            if tool == .searchFiles, pattern == nil {
                throw MCPClientError.toolFailed("pattern must be a glob string.")
            }
            var count = 0
            var matches: [String] = []
            func walk(_ directory: URL, relative: String, depth: Int) throws -> [[String: Any]] {
                guard depth <= 64 else {
                    throw MCPClientError.toolFailed("The directory tree exceeds the safety limit.")
                }
                try Task.checkCancellation()
                try validateScope()
                var tree: [[String: Any]] = []
                for entry in try visibleEntries(at: directory) {
                    count += 1
                    guard count <= maximumEntries else {
                        throw MCPClientError.toolFailed(
                            "The directory tree exceeds the safety limit.")
                    }
                    let relativePath = relative.isEmpty ? entry.name : "\(relative)/\(entry.name)"
                    guard !excludes.contains(where: { matchesGlob(relativePath, pattern: $0) })
                    else {
                        continue
                    }
                    let child = directory.appendingPathComponent(entry.name)
                    if let pattern, matchesGlob(relativePath, pattern: pattern) {
                        matches.append(child.path)
                    }
                    var value: [String: Any] = [
                        "name": entry.name, "type": entry.isDirectory ? "directory" : "file",
                    ]
                    if entry.isDirectory {
                        value["children"] = try walk(
                            child, relative: relativePath, depth: depth + 1)
                    }
                    if tool == .directoryTree { tree.append(value) }
                }
                return tree
            }
            let tree = try walk(url, relative: "", depth: 0)
            result =
                tool == .directoryTree
                ? try json(tree)
                : (matches.isEmpty ? "No matches found" : matches.joined(separator: "\n"))

        case .getFileInfo:
            let entry = try directories.metadata(at: readPath(path()))
            result =
                "size: \(entry.size)\nisDirectory: \(entry.isDirectory)\npermissions: \(String(entry.permissions, radix: 8))\nmodified: \(entry.modified)"

        case .listAllowedDirectories:
            result = "Allowed directory for this call:\n\(root.path)"
        }
        try validateScope()
        return result.count > maximumResultCharacters
            ? String(result.prefix(maximumResultCharacters)) + "\n[Result truncated]" : result
    }

    private static func arguments(_ json: String?) throws -> [String: Any] {
        guard let json else { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else {
            throw MCPClientError.toolFailed("Tool arguments must be a JSON object.")
        }
        return value
    }

    private static func lineLimit(_ key: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let count = value as? Int, count > 0 else {
            throw MCPClientError.toolFailed("\(key) must be a positive integer.")
        }
        return count
    }

    private static func json(_ value: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            as: UTF8.self)
    }

    private static func matchesGlob(_ path: String, pattern: String) -> Bool {
        // Keep '*' within one component; '**' spans directories.
        let pieces = pattern.components(separatedBy: "**")
        let expression = pieces.map { piece in
            NSRegularExpression.escapedPattern(for: piece)
                .replacingOccurrences(of: "\\*", with: "[^/]*")
                .replacingOccurrences(of: "\\?", with: "[^/]")
        }.joined(separator: ".*")
        let normalized = expression.replacingOccurrences(of: ".*/", with: "(?:.*/)?")
        return path.range(of: "^(?:\(normalized))$", options: .regularExpression) != nil
    }
}
