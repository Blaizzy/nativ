import Foundation

/// Readable files for session-owned work. IDs keep duplicate names and different chats separate.
struct ChatWorkFileStore {
    let root: URL
    private let fileManager = FileManager.default

    func directory(for sessionID: UUID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func fileURL(for item: ChatWorkItem, sessionID: UUID) -> URL? {
        guard item.canEdit else { return nil }
        return directory(for: sessionID)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.storedFilename)
    }

    func createDirectory(for sessionID: UUID) throws {
        let directory = directory(for: sessionID)
        try checkLocation(directory, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Save only changed sources. Ordinary chat saves must not overwrite an external editor's work.
    func save(_ state: ChatWorkState, previous: ChatWorkState?, sessionID: UUID) throws {
        var writes: [(URL, String)] = []
        for item in state.items where item.canEdit {
            guard let url = fileURL(for: item, sessionID: sessionID) else { continue }
            try checkLocation(url)
            let old = previous?.items.first { $0.id == item.id }
            let oldURL = old.flatMap { fileURL(for: $0, sessionID: sessionID) }
            let exists = fileManager.fileExists(atPath: url.path)
            if exists, oldURL == url, old?.content == item.content { continue }
            if exists {
                let disk = try read(url)
                if disk == item.content { continue }
                guard oldURL == url, disk == old?.content else { throw ChatWorkError.conflict }
            } else if let oldURL, oldURL != url, fileManager.fileExists(atPath: oldURL.path) {
                let disk = try read(oldURL)
                guard disk == old?.content || disk == item.content else { throw ChatWorkError.conflict }
            }
            writes.append((url, item.content))
        }
        for (url, content) in writes {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Bring edits made in Finder, an editor, or the terminal back into the same side-pane item.
    func refreshed(_ state: ChatWorkState, sessionID: UUID) throws -> ChatWorkState {
        var result = state
        for index in result.items.indices {
            let item = result.items[index]
            guard let url = fileURL(for: item, sessionID: sessionID) else { continue }
            try checkLocation(url)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let content = try read(url)
            if content != item.content {
                result.items[index].content = content
                result.items[index].revision += 1
                result.items[index].updatedBy = "File"
            }
        }
        return result
    }

    /// Remove an old filename only after the chat saved successfully, and only if it is unchanged.
    func removeRenamedFiles(previous: ChatWorkState?, current: ChatWorkState, sessionID: UUID) {
        for old in previous?.items ?? [] {
            guard let item = current.items.first(where: { $0.id == old.id }),
                  let oldURL = fileURL(for: old, sessionID: sessionID),
                  let newURL = fileURL(for: item, sessionID: sessionID), oldURL != newURL,
                  (try? read(oldURL)) == old.content else { continue }
            try? fileManager.removeItem(at: oldURL)
        }
    }

    private func read(_ url: URL) throws -> String {
        try checkLocation(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= ChatWorkState.maximumContentBytes else {
            throw ChatWorkError.invalid("\(url.lastPathComponent) must be a UTF-8 text file up to 256 KB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= ChatWorkState.maximumContentBytes, let text = String(data: data, encoding: .utf8) else {
            throw ChatWorkError.invalid("\(url.lastPathComponent) must be a UTF-8 text file up to 256 KB.")
        }
        return text
    }

    private func checkLocation(_ url: URL, isDirectory: Bool = false) throws {
        var component = url
        while component.path.count >= root.path.count {
            if let values = try? component.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
               values.isSymbolicLink == true || ((component != url || isDirectory) && values.isDirectory == false) {
                throw ChatWorkError.invalid("The chat files folder contains a link or invalid folder: \(component.path)")
            }
            if component == root { break }
            component.deleteLastPathComponent()
        }
    }
}

extension ChatWorkItem {
    var storedFilename: String {
        var name = exportFilename.components(separatedBy: CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "Untitled" }
        if (name as NSString).pathExtension.isEmpty {
            let extensions = ["swift": "swift", "python": "py", "javascript": "js", "typescript": "ts",
                              "json": "json", "css": "css", "shell": "sh", "bash": "sh", "html": "html"]
            let ext = resolvedKind == .document ? "md" : resolvedKind == .website ? "html"
                : extensions[language?.lowercased() ?? ""] ?? "txt"
            name += "." + ext
        }
        // Preserve the extension while staying within filesystem component limits for Unicode titles.
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        if ext.utf8.count > 40 { return String(id.uuidString.prefix(8)) + ".txt" }
        while (stem + "." + ext).utf8.count > 240 { stem.removeLast() }
        return stem + "." + ext
    }
}
