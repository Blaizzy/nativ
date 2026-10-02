import Foundation

/// A self-contained Git bundle, independent of the deleted chat and repository refs.
struct ChatWorktreeSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let title: String
    let createdAt: Date
    let worktree: ChatGitWorktree
    let head: String
    let commit: String
    let indexTree: String
    let workingTree: String
    let ignoredFiles: [String]
    var workState: ChatWorkState? = nil
    var checkoutHead: ChatGitHead? = nil

    var ref: String { "refs/nativ/recovery/\(id.uuidString.lowercased())" }
}

extension ChatGitWorktreeStore {
    var recoveryRoot: URL { root.deletingLastPathComponent().appendingPathComponent("DeletedWorktrees", isDirectory: true) }

    func snapshots() throws -> [ChatWorktreeSnapshot] {
        guard FileManager.default.fileExists(atPath: recoveryRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try loadSnapshot(UUID(uuidString: $0.lastPathComponent)!) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func loadSnapshot(_ id: UUID) throws -> ChatWorktreeSnapshot {
        let snapshot = try JSONDecoder().decode(ChatWorktreeSnapshot.self,
            from: Data(contentsOf: snapshotDirectory(id).appendingPathComponent("snapshot.json")))
        guard snapshot.id == id else { throw ChatGitWorktreeError(message: "The recovery record is invalid.") }
        return snapshot
    }

    func snapshotDirectory(_ id: UUID) -> URL {
        recoveryRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Uses an alternate index: saving a snapshot never stages or commits changes in the user's index.
    func workingTree(at path: String, indexTree: String) throws -> String {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("nativ-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        _ = try git(["read-tree", indexTree], at: path, environment: environment)
        _ = try git(["add", "--all", "--", "."], at: path, environment: environment)
        return try git(["write-tree"], at: path, environment: environment)
    }

    func snapshot(_ worktree: ChatGitWorktree, sessionID: UUID, title: String,
                  state: ChatGitWorktreeRemoval, workState: ChatWorkState? = nil) throws -> ChatWorktreeSnapshot? {
        // A retry after successful cleanup must not replace the previous snapshot with an empty one.
        let exists = FileManager.default.fileExists(atPath: worktree.path)
        guard let head = state.headCommit else {
            guard !exists else { throw ChatGitWorktreeError(message: "The checkout has no readable HEAD. Its files have been kept.") }
            return nil
        }
        let indexTree = try exists ? git(["write-tree"], at: worktree.path)
            : git(["rev-parse", "\(head)^{tree}"], at: worktree.repositoryPath)
        let tree = try exists ? workingTree(at: worktree.path, indexTree: indexTree) : indexTree
        for treeID in Set([tree, indexTree]) {
            guard !(try git(["ls-tree", "-r", treeID], at: worktree.repositoryPath))
                .components(separatedBy: "\n").contains(where: { $0.hasPrefix("160000 ") }) else {
                throw ChatGitWorktreeError(message: "This worktree contains a submodule or nested Git repository. Its files cannot be fully snapshotted; the chat and checkout have been kept.")
            }
        }
        let identity = ["GIT_AUTHOR_NAME": "Nativ", "GIT_AUTHOR_EMAIL": "snapshot@nativ.local",
                        "GIT_COMMITTER_NAME": "Nativ", "GIT_COMMITTER_EMAIL": "snapshot@nativ.local"]
        let indexCommit = try git(["commit-tree", indexTree, "-p", head, "-m", "Nativ saved index"],
                                  at: worktree.repositoryPath, environment: identity)
        let commit = try git(["commit-tree", tree, "-p", indexCommit, "-m", "Nativ worktree recovery"],
                             at: worktree.repositoryPath, environment: identity)
        // Only file-tab metadata belongs in the record. Contents come from the verified bundle,
        // so ignored or deleted files cannot be resurrected from stale chat JSON.
        var fileTabs = workState
        fileTabs?.items = workState?.items.filter(\.canEdit).map { item in
            var metadata = item
            metadata.title = item.storedFilename
            metadata.content = ""
            return metadata
        } ?? []
        let record = ChatWorktreeSnapshot(id: UUID(), sessionID: sessionID, title: title, createdAt: Date(),
            worktree: worktree, head: head, commit: commit, indexTree: indexTree, workingTree: tree,
            ignoredFiles: state.ignoredFiles, workState: fileTabs, checkoutHead: state.checkoutHead)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let staging = recoveryRoot.appendingPathComponent(".saving-\(record.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try git(["update-ref", record.ref, commit], at: worktree.repositoryPath)
        defer { _ = try? git(["update-ref", "-d", record.ref, commit], at: worktree.repositoryPath) }
        let bundle = staging.appendingPathComponent("snapshot.bundle")
        _ = try git(["bundle", "create", bundle.path, record.ref], at: worktree.repositoryPath)
        // Verification in an empty repository proves that the bundle has no external prerequisites.
        try verify(record, bundle: bundle)
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
        _ = try JSONDecoder().decode(ChatWorktreeSnapshot.self,
            from: Data(contentsOf: staging.appendingPathComponent("snapshot.json")))
        try FileManager.default.moveItem(at: staging, to: snapshotDirectory(record.id))
        return record
    }

    private func verify(_ record: ChatWorktreeSnapshot, bundle: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nativ-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try git(["init", "--bare", "."], at: temporary.path)
        _ = try git(["bundle", "verify", bundle.path], at: temporary.path)
        _ = try git(["fetch", "--no-tags", bundle.path, "\(record.ref):\(record.ref)"], at: temporary.path)
        _ = try git(["fsck", "--full", "--strict", record.commit], at: temporary.path)
        guard try git(["rev-parse", record.ref], at: temporary.path) == record.commit,
              try git(["rev-parse", "\(record.commit)^{tree}"], at: temporary.path) == record.workingTree,
              try git(["rev-parse", "\(record.commit)^1^{tree}"], at: temporary.path) == record.indexTree,
              try git(["rev-parse", "\(record.commit)^1^1"], at: temporary.path) == record.head else {
            throw ChatGitWorktreeError(message: "The worktree snapshot could not be verified. The checkout has been kept.")
        }
    }

    func restorationPlan(_ record: ChatWorktreeSnapshot, sessionID: UUID) throws -> ChatGitWorktree {
        let common = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: record.worktree.repositoryPath)
        guard URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath().path == record.worktree.commonDirectory else {
            throw ChatGitWorktreeError(message: "The original repository is unavailable. Restore it to its original location and try again. The snapshot has been kept.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let storage = FileWriteAccessPolicy.configuredRootURL(rootPath: root.path) else {
            throw ChatGitWorktreeError(message: "The worktree storage folder is unavailable.")
        }
        let id = sessionID.uuidString.lowercased()
        return ChatGitWorktree(repositoryPath: record.worktree.repositoryPath, commonDirectory: record.worktree.commonDirectory,
            path: storage.appendingPathComponent(id).path, projectSubpath: record.worktree.projectSubpath,
            branch: "nativ/\(id)", baseCommit: record.head)
    }

    func restore(_ id: UUID, to plan: ChatGitWorktree) throws -> ChatGitWorktree {
        let record = try loadSnapshot(id)
        guard let sessionID = UUID(uuidString: URL(fileURLWithPath: plan.path).lastPathComponent),
              plan == (try restorationPlan(record, sessionID: sessionID)),
              !FileManager.default.fileExists(atPath: plan.path),
              (try? git(["rev-parse", "--verify", "refs/heads/\(plan.branch)"], at: plan.repositoryPath)) == nil else {
            throw ChatGitWorktreeError(message: "The restore destination is already in use. Its files and the snapshot have been kept.")
        }
        let bundle = snapshotDirectory(id).appendingPathComponent("snapshot.bundle")
        try verify(record, bundle: bundle)
        let ref = "refs/nativ/restore/\(sessionID.uuidString.lowercased())"
        _ = try git(["fetch", "--no-tags", bundle.path, "\(record.ref):\(ref)"], at: plan.repositoryPath)
        defer { _ = try? git(["update-ref", "-d", ref, record.commit], at: plan.repositoryPath) }
        _ = try git(["worktree", "add", "-b", plan.branch, "--", plan.path, record.commit], at: plan.repositoryPath)
        // Preserve the original branch tip and staged/unstaged distinction, not the synthetic snapshot commits.
        _ = try git(["reset", "--mixed", record.head], at: plan.path)
        _ = try git(["read-tree", record.indexTree], at: plan.path)
        var ready = plan
        ready.isReady = true
        guard ready.availableRootPath != nil else {
            throw ChatGitWorktreeError(message: "The files were restored at \(plan.path), but the project subfolder is unavailable. The snapshot has been kept.")
        }
        return ready
    }

    func permanentlyDeleteSnapshot(_ id: UUID) throws {
        _ = try loadSnapshot(id)
        // Only the recovery record and its bundle are removed. Live checkouts and branches are untouched.
        try FileManager.default.removeItem(at: snapshotDirectory(id))
    }
}
