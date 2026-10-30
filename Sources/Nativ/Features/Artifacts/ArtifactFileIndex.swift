import Combine
import CoreServices
import CryptoKit
import Darwin
import Foundation
import OSLog
import Observation

@MainActor
final class ArtifactFileIndexCoordinator: ObservableObject {
    @Published private(set) var revision = 0
    let worker: ArtifactFileIndexer
    private let root: URL
    private var changes: AnyCancellable?
    private var watcher: ArtifactFileWatcher?
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var manifests: [UUID: ArtifactFileManifest] = [:]
    private var paths = Set<String>()
    private var reconcile = true
    private var retryNeedsScan = false
    private static let logger = Logger(subsystem: "Nativ", category: "FileIndex")

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Nativ/Chat"), indexURL: URL? = nil) {
        self.root = ChatWorkFileStore.canonicalRoot(root)
        worker = ArtifactFileIndexer(root: root, indexURL: indexURL ?? root.deletingLastPathComponent().appending(path: "Artifact Files.sqlite"))
        changes = NotificationCenter.default.publisher(for: ArtifactFileManifest.changed).sink { [weak self] event in
            guard let manifest = event.object as? ArtifactFileManifest else { return }
            Task { @MainActor [weak self] in
                guard let self, ChatWorkFileStore.canonicalRoot(manifest.root).path == self.root.path else { return }
                self.manifests[manifest.sessionID] = manifest
                self.schedule()
            }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            watcher = ArtifactFileWatcher(root: self.root) { [weak self] paths, reconcile in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.paths.formUnion(paths.map { path in
                        let url = URL(fileURLWithPath: path)
                        return ArtifactFileIndexer.canonicalPath(url, root: self.root)
                    }.filter {
                        $0.hasPrefix(self.root.appending(path: "Sessions").path + "/")
                            || $0.hasPrefix(self.root.appending(path: "Files").path + "/")
                            || $0.contains("/Nativ Files/")
                    })
                    self.reconcile = self.reconcile || reconcile
                    guard !self.paths.isEmpty || self.reconcile else { return }
                    self.schedule()
                }
            }
        } catch { Self.logger.error("File index watcher unavailable: \(error.localizedDescription, privacy: .public)") }
        schedule()
    }

    private func schedule() {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.flush()
        }
    }

    private func flush() async {
        defer { task = nil; if !manifests.isEmpty || !paths.isEmpty || reconcile { schedule() } }
        let snapshots = Array(manifests.values), changedPaths = Array(paths), needsScan = reconcile
        manifests.removeAll(); paths.removeAll(); reconcile = false
        do {
            for manifest in snapshots { try await worker.receive(manifest) }
            try await worker.changed(paths: changedPaths, reconcile: needsScan)
            try await worker.drain()
            revision &+= 1
            if try await worker.hasPending() { scheduleRetry() }
            if watcher == nil { scheduleRetry(reconcile: true) }
        } catch {
            scheduleRetry(reconcile: true)
            Self.logger.error("Background file indexing deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleRetry(reconcile needsScan: Bool = false) {
        retryNeedsScan = retryNeedsScan || needsScan
        guard retryTask == nil else { return }
        retryTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.reconcile = self.reconcile || self.retryNeedsScan
            self.retryNeedsScan = false
            self.schedule()
        }
    }

    deinit { task?.cancel(); retryTask?.cancel() }
}

actor ArtifactFileIndexer {
    let root: URL
    private let indexURL: URL
    private var storage: ArtifactFileIndexStore?
    private var draining = false
    private var discovered = false
    private(set) var contentReads = 0
    private(set) var sessionReads = 0
    private static let logger = Logger(subsystem: "Nativ", category: "FileIndex")

    init(root: URL, indexURL: URL) { self.root = ChatWorkFileStore.canonicalRoot(root); self.indexURL = indexURL }

    nonisolated static func canonicalPath(_ url: URL, root: URL) -> String {
        let alias = root.standardizedFileURL.path + "/"
        if url.path.hasPrefix(alias) { return root.path + "/" + url.path.dropFirst(alias.count) }
        return url.path
    }

    private func store() throws -> ArtifactFileIndexStore {
        if let storage { return storage }
        let opened: ArtifactFileIndexStore
        do { opened = try ArtifactFileIndexStore(url: indexURL) }
        catch let error as NSError where error.domain == "ArtifactFileIndex" && [11, 26].contains(error.code & 0xff) {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: indexURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            opened = try ArtifactFileIndexStore(url: indexURL)
        }
        storage = opened
        return opened
    }

    nonisolated static func stamp(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    func receive(_ manifest: ArtifactFileManifest) throws {
        guard ChatWorkFileStore.canonicalRoot(manifest.root).path == root.path else { return }
        let url = root.appending(path: "Sessions/\(manifest.sessionID).json")
        guard Self.stamp(url) == manifest.stamp else { return }
        try store().synchronize(session: manifest.sessionID.uuidString, stamp: manifest.stamp, files: manifest.files)
    }

    func discover() async throws {
        let database = try store()
        let directory = root.appending(path: "Sessions")
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { urls = [] }
        var live = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            live.insert(id.uuidString)
            try Task.checkCancellation()
            try discoverSession(url)
            try await Task.sleep(for: .milliseconds(5))
        }
        for id in try database.sessionIDs() where !live.contains(id)
            && !FileManager.default.fileExists(atPath: directory.appending(path: "\(id).json").path) {
            try database.removeSession(id)
        }
        for (id, path, stamp, encodedAccess) in try database.paths() {
            let access = try? JSONDecoder().decode(ChatWorkFileAccess.self, from: Data(encodedAccess.utf8))
            if access?.validatedURL == nil || Self.stamp(URL(fileURLWithPath: path)) != stamp {
                try database.markPending(id: id)
            }
        }
        discovered = true
    }

    private func discoverSession(_ url: URL) throws {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return }
        let database = try store()
        guard let stamp = Self.stamp(url) else { return }
        guard try database.sessionStamp(id.uuidString) != stamp else { return }
        sessionReads += 1
        do {
            let manifest = try ArtifactFileManifest.load(url, root: root, stamp: stamp)
            try receive(manifest)
        } catch {
            try database.deferSession(id.uuidString)
            Self.logger.error("File discovery deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    func changed(paths: [String], reconcile: Bool = false) async throws {
        if reconcile { try await discover(); return }
        let sessions = root.appending(path: "Sessions").path + "/"
        for original in Set(paths) {
            let source = URL(fileURLWithPath: original)
            let path = Self.canonicalPath(source, root: root)
            if path.hasPrefix(sessions), path.hasSuffix(".json") {
                let url = URL(fileURLWithPath: path)
                if Self.stamp(url) != nil { try discoverSession(url) }
                else if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                        FileManager.default.fileExists(atPath: root.appending(path: "Sessions").path) {
                    try store().removeSession(id.uuidString)
                }
            } else {
                try store().markPath(path)
            }
        }
    }

    func drain() async throws {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        for id in try store().pendingSessions() {
            let url = root.appending(path: "Sessions/\(id).json")
            if Self.stamp(url) != nil { try discoverSession(url) }
            else { try store().deferSession(id) }
        }
        while let pending = try store().pending() {
            try Task.checkCancellation()
            do { try index(pending) }
            catch {
                try store().deferFile(pending.file.id)
                Self.logger.debug("File indexing deferred: \(error.localizedDescription, privacy: .public)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if discovered { try store().markBackfillComplete() }
    }

    private func index(_ pending: ArtifactFileIndexStore.Pending) throws {
        let access = try JSONDecoder().decode(ChatWorkFileAccess.self, from: Data(pending.file.access.utf8))
        guard let url = access.validatedURL, url.path == pending.file.path else { throw CocoaError(.fileReadNoPermission) }
        guard let before = Self.stamp(url) else { throw CocoaError(.fileReadNoSuchFile) }
        if !pending.force, before == pending.stamp {
            try store().finish(pending.file.id, stamp: before, hash: pending.hash, body: nil)
            return
        }
        contentReads += 1
        let bytes: Data
        do { bytes = try SafeLocalFileReader(maximumBytes: 2_000_000).readSynchronously(url: url).data }
        catch SafeLocalFileReaderError.fileTooLarge {
            try store().finish(pending.file.id, stamp: before, hash: "oversized", body: "")
            return
        }
        guard before == Self.stamp(url) else { throw CocoaError(.fileReadUnknown) }
        let hash = Data(SHA256.hash(data: bytes)).base64EncodedString()
        let body = bytes.count <= 2_000_000 && !bytes.contains(0) ? String(data: bytes, encoding: .utf8) ?? "" : ""
        try store().finish(pending.file.id, stamp: before, hash: hash, body: hash == pending.hash ? nil : body)
    }

    func hasPending() throws -> Bool { try store().hasPending() }
    func search(_ query: String) throws -> [String] { try store().search(query) }
}

final class ArtifactFileWatcher {
    private var stream: FSEventStreamRef?
    private let changed: @Sendable ([String], Bool) -> Void

    init?(root: URL, changed: @escaping @Sendable ([String], Bool) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let options = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let observer = Unmanaged<ArtifactFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let strings = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            let directoryMutation = kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved
            let reconcile = (0..<count).contains {
                flags[$0] & UInt32(lost) != 0 || (flags[$0] & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                    && flags[$0] & UInt32(directoryMutation) != 0)
            }
            observer.changed(strings, reconcile)
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(options)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}

@MainActor @Observable
final class ArtifactFileSearch {
    struct Request: Equatable {
        let query: String
        let revision: Int
    }

    private(set) var query = ""
    private(set) var matches: [UUID] = []
    private(set) var error: String?
    private(set) var isSearching = false

    func matches(for query: String) -> [UUID] { self.query == query ? matches : [] }

    func update(_ query: String, using worker: ArtifactFileIndexer) async {
        guard !Task.isCancelled else { return }
        if self.query != query { matches = [] }
        self.query = query
        error = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(150))
            let ids = try await worker.search(query)
            try Task.checkCancellation()
            matches = ids.compactMap(UUID.init(uuidString:))
            isSearching = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "File search is unavailable. Try again."
            isSearching = false
        }
    }
}
