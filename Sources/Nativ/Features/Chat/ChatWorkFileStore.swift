import Foundation

/// Readable files for session-owned work. IDs keep duplicate names and different chats separate.
struct ChatWorkFileStore {
    let root: URL
    var worktree: ChatGitWorktree? = nil
    private let fileManager = FileManager.default

    func directory(for sessionID: UUID) -> URL {
        worktree == nil ? root.appendingPathComponent(sessionID.uuidString, isDirectory: true) : root
    }

    func fileURL(for item: ChatWorkItem, sessionID: UUID) -> URL? {
        guard item.canEdit, worktree == nil || worktree?.availableRootPath != nil else { return nil }
        return directory(for: sessionID)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.storedFilename)
    }

    func createDirectory(for sessionID: UUID) throws {
        let directory = directory(for: sessionID)
        try checkLocation(directory, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Keep the source recoverable, and restore it if removing its chat reference fails.
    func delete(_ item: ChatWorkItem, sessionID: UUID,
                trashFile: (URL) throws -> URL, save: () throws -> Void) throws {
        guard let url = fileURL(for: item, sessionID: sessionID) else {
            throw ChatWorkError.invalid("Only saved files can be deleted.")
        }
        try checkLocation(url)
        var trashedURL: URL?
        if fileManager.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ChatWorkError.invalid("The file location is not a regular file.")
            }
            trashedURL = try trashFile(url)
        }
        do {
            try save()
        } catch {
            if let trashedURL {
                do {
                    try checkLocation(url)
                    try fileManager.moveItem(at: trashedURL, to: url)
                } catch {
                    throw ChatWorkError.invalid("The chat could not be saved and the file could not be restored. Recover it from Trash at \(trashedURL.path).")
                }
            }
            throw error
        }
    }

    static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw ChatWorkError.invalid("The file's Trash location could not be found.") }
        return result as URL
    }

    /// Save only changed sources. Ordinary chat saves must not overwrite an external editor's work.
    func save(_ state: ChatWorkState, previous: ChatWorkState?, sessionID: UUID,
              materializeMissing: Bool = true) throws {
        var writes: [(URL, String)] = []
        for item in state.items where item.canEdit {
            let old = previous?.items.first { $0.id == item.id }
            // Git or a terminal may delete a file. Metadata-only chat saves must not recreate it.
            if worktree != nil, old?.storedFilename == item.storedFilename, old?.content == item.content { continue }
            guard let url = fileURL(for: item, sessionID: sessionID) else { throw ChatWorkError.unavailable }
            let oldURL = old.flatMap { fileURL(for: $0, sessionID: sessionID) }
            // Only an explicit refresh materializes missing files from older chats.
            // Metadata and transcript saves do no filesystem work for unchanged sources.
            if !materializeMissing, oldURL == url, old?.content == item.content { continue }
            try checkLocation(directory(for: sessionID), isDirectory: true)
            try checkLocation(url)
            let exists = fileManager.fileExists(atPath: url.path)
            if worktree != nil, let oldURL, !fileManager.fileExists(atPath: oldURL.path) {
                throw ChatWorkError.conflict
            }
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

    /// Copy an older chat's sources into its checkout without overwriting either location.
    /// Legacy copies are retained for recovery, but are no longer used after migration.
    func migrate(_ state: ChatWorkState, previous: ChatWorkState?, from legacy: ChatWorkFileStore,
                 sessionID: UUID) throws {
        var sources = state
        for index in sources.items.indices where sources.items[index].canEdit {
            let item = sources.items[index]
            let old = previous?.items.first { $0.id == item.id } ?? item
            if let source = legacy.fileURL(for: old, sessionID: sessionID), fileManager.fileExists(atPath: source.path) {
                let disk = try legacy.read(source)
                if disk != old.content {
                    guard item.content == old.content || item.content == disk else { throw ChatWorkError.conflict }
                    sources.items[index].content = disk
                }
            }
        }
        try save(sources, previous: nil, sessionID: sessionID)
    }

    /// Bring edits made in Finder, an editor, or the terminal back into the same side-pane item.
    func refreshed(_ state: ChatWorkState, sessionID: UUID, droppingMissing: Bool = false) throws -> ChatWorkState {
        var result = state
        if droppingMissing {
            result.items.removeAll { item in
                guard item.canEdit else { return false }
                guard let url = fileURL(for: item, sessionID: sessionID) else { return true }
                return !fileManager.fileExists(atPath: url.path)
            }
            result.openIDs.removeAll { id in !result.items.contains { $0.id == id } }
            if !result.items.contains(where: { $0.id == result.selectedID }) { result.selectedID = nil }
        }
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
        if let worktree, worktree.availableRootPath == nil {
            throw ChatWorkError.invalid("The chat worktree is unavailable. Restore its checkout before changing files.")
        }
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
