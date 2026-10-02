import Foundation

/// Read from Git each time it is needed, rather than persisting a second current-branch value.
enum ChatGitHead: Codable, Equatable, Sendable {
    case branch(String)
    case detached(String)

    init?(contents: String) {
        let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if value.hasPrefix(prefix), value.count > prefix.count {
            self = .branch(String(value.dropFirst(prefix.count)))
        } else if [40, 64].contains(value.count), value.allSatisfy({ $0.isHexDigit }) {
            self = .detached(value)
        } else {
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .branch(let name): name
        case .detached(let commit): "Detached HEAD · \(commit.prefix(8))"
        }
    }
}

/// Persisted with the chat so reopening it never falls back to the local project.
struct ChatGitWorktree: Codable, Equatable, Sendable {
    let repositoryPath: String
    let commonDirectory: String
    let path: String
    let projectSubpath: String
    let branch: String // The branch Nativ created and owns, not necessarily the current branch.
    let baseCommit: String
    var isReady = false

    var projectPath: String {
        projectSubpath.isEmpty ? path : URL(fileURLWithPath: path).appendingPathComponent(projectSubpath).path
    }

    /// Check Git's two-way worktree registration without spawning a process on the UI thread.
    var registered: Bool { registeredDirectory != nil }

    var currentHead: ChatGitHead? {
        guard let admin = registeredDirectory,
              let contents = try? String(contentsOf: admin.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        return ChatGitHead(contents: contents)
    }

    private var registeredDirectory: URL? {
        let marker = URL(fileURLWithPath: path).appendingPathComponent(".git")
        guard let line = try? String(contentsOf: marker, encoding: .utf8), line.hasPrefix("gitdir: ") else { return nil }
        let admin = URL(fileURLWithPath: String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines),
                        relativeTo: marker.deletingLastPathComponent()).standardizedFileURL
        guard let common = try? String(contentsOf: admin.appendingPathComponent("commondir"), encoding: .utf8),
              let backlink = try? String(contentsOf: admin.appendingPathComponent("gitdir"), encoding: .utf8) else { return nil }
        guard URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: admin)
            .standardizedFileURL.resolvingSymlinksInPath().path == commonDirectory
            && URL(fileURLWithPath: backlink.trimmingCharacters(in: .whitespacesAndNewlines))
                .standardizedFileURL.resolvingSymlinksInPath() == marker.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        return admin
    }

    /// Only an explicitly scoped, registered checkout may be accessed inside Nativ's private data folder.
    static func isManagedProjectRoot(_ root: URL) -> Bool {
        var checkout = root.standardizedFileURL
        while checkout.path != "/" {
            let storage = checkout.deletingLastPathComponent()
            if UUID(uuidString: checkout.lastPathComponent) != nil,
               storage.lastPathComponent == "Worktrees",
               storage.deletingLastPathComponent().lastPathComponent == "Chat",
               storage.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Nativ" {
                let marker = checkout.appendingPathComponent(".git")
                guard let line = try? String(contentsOf: marker, encoding: .utf8), line.hasPrefix("gitdir: ") else { return false }
                let admin = URL(fileURLWithPath: String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines),
                                relativeTo: checkout).standardizedFileURL
                guard let common = try? String(contentsOf: admin.appendingPathComponent("commondir"), encoding: .utf8) else { return false }
                let commonPath = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: admin)
                    .standardizedFileURL.resolvingSymlinksInPath().path
                return ChatGitWorktree(repositoryPath: "", commonDirectory: commonPath, path: checkout.path,
                                       projectSubpath: "", branch: "", baseCommit: "").registered
            }
            checkout = storage
        }
        return false
    }

    var availableRootPath: String? {
        guard isReady, registered,
              let root = FileWriteAccessPolicy.configuredRootURL(rootPath: projectPath),
              root.path == URL(fileURLWithPath: projectPath).path,
              FileReadAccessPolicy.isConfigured(rootPath: root.path) else { return nil }
        return root.path
    }
}

struct ChatGitWorktreeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ChatGitWorktreeRemoval: Sendable {
    let hasCheckout: Bool
    let checkoutHead: ChatGitHead?
    let headCommit: String?
    let branchCommit: String?
    let removesManagedBranch: Bool
    let hasUncommittedFiles: Bool
    let hasUnmergedCommits: Bool
    let ignoredFiles: [String]

    var requiresConfirmation: Bool { !ignoredFiles.isEmpty }
    var warning: String {
        let examples = ignoredFiles.prefix(5).joined(separator: "\n")
        return "Git history and uncommitted work will be saved in Recently deleted worktrees. These ignored files or folders won’t be saved and will be permanently removed:\n\n\(examples)\(ignoredFiles.count > 5 ? "\n…and more" : "")\n\nCopy any ignored files you need before continuing."
    }
}

/// All Git operations run off the main actor, with argument arrays rather than shell interpolation.
struct ChatGitWorktreeStore: Sendable {
    let root: URL

    func currentHead(at path: String) throws -> ChatGitHead? {
        let directory = try git(["rev-parse", "--absolute-git-dir"], at: path)
        return ChatGitHead(contents: try String(contentsOf: URL(fileURLWithPath: directory)
            .appendingPathComponent("HEAD"), encoding: .utf8))
    }

    func plan(projectPath: String, sessionID: UUID) throws -> ChatGitWorktree {
        guard let project = FileWriteAccessPolicy.configuredRootURL(rootPath: projectPath) else {
            throw ChatGitWorktreeError(message: "The project folder is unavailable.")
        }
        guard (try? git(["rev-parse", "--is-inside-work-tree"], at: project.path)) == "true" else {
            throw ChatGitWorktreeError(message: "Worktree requires a Git repository. Choose Local for this folder.")
        }
        let repository = URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], at: project.path))
        guard let commit = try? git(["rev-parse", "--verify", "HEAD^{commit}"], at: repository.path) else {
            throw ChatGitWorktreeError(message: "Make an initial commit in the project before creating a worktree.")
        }
        let common = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: repository.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let storage = FileWriteAccessPolicy.configuredRootURL(rootPath: root.path) else {
            throw ChatGitWorktreeError(message: "The worktree storage folder is unavailable.")
        }
        let subpath = project.path == repository.path ? "" : String(project.path.dropFirst(repository.path.count + 1))
        return ChatGitWorktree(
            repositoryPath: repository.path,
            commonDirectory: URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath().path,
            path: storage.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true).path,
            projectSubpath: subpath,
            branch: "nativ/\(sessionID.uuidString.lowercased())",
            baseCommit: commit
        )
    }

    func create(_ plan: ChatGitWorktree) throws -> ChatGitWorktree {
        var result = plan
        // A previous launch may have finished Git's checkout before saving the ready state.
        if !plan.registered {
            guard !FileManager.default.fileExists(atPath: plan.path) else {
                throw ChatGitWorktreeError(message: "The worktree folder already exists but is not registered with this repository: \(plan.path)")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let existingCommit = try? git(["rev-parse", "--verify", "refs/heads/\(plan.branch)"], at: plan.repositoryPath)
            if let existingCommit {
                guard existingCommit == plan.baseCommit else {
                    throw ChatGitWorktreeError(message: "The worktree branch already contains different work. It has been preserved: \(plan.branch)")
                }
                // Git may have created the branch before a previous checkout was interrupted.
                _ = try git(["worktree", "add", "--", plan.path, plan.branch], at: plan.repositoryPath)
            } else {
                _ = try git(["worktree", "add", "-b", plan.branch, "--", plan.path, plan.baseCommit], at: plan.repositoryPath)
            }
        }
        result.isReady = true
        guard result.availableRootPath != nil else {
            throw ChatGitWorktreeError(message: "The worktree was created, but the project folder is unavailable in that commit: \(plan.projectPath)")
        }
        return result
    }

    func removal(_ worktree: ChatGitWorktree, sessionID: UUID) throws -> ChatGitWorktreeRemoval {
        let id = sessionID.uuidString.lowercased()
        let storage = FileWriteAccessPolicy.configuredRootURL(rootPath: root.path)
        let expectedPath = storage?.appendingPathComponent(id, isDirectory: true).path
        guard worktree.path == expectedPath, worktree.branch == "nativ/\(id)" else {
            throw ChatGitWorktreeError(message: "This checkout is outside the chat's managed worktree folder. It has been preserved.")
        }
        let common = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: worktree.repositoryPath)
        guard URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath().path == worktree.commonDirectory else {
            throw ChatGitWorktreeError(message: "The worktree's original repository could not be verified. It has been preserved.")
        }
        let entries = try git(["worktree", "list", "--porcelain", "-z"], at: worktree.repositoryPath)
            .components(separatedBy: "\0\0").map { $0.components(separatedBy: "\0") }
        let checkout = entries.first { $0.contains("worktree \(worktree.path)") }
        let branchRef = "refs/heads/\(worktree.branch)"
        let branchIsInUseElsewhere = entries.contains {
            $0.contains("branch \(branchRef)") && !$0.contains("worktree \(worktree.path)")
        }
        let exists = FileManager.default.fileExists(atPath: worktree.path)
        if exists {
            guard worktree.registered, checkout != nil,
                  FileWriteAccessPolicy.configuredRootURL(rootPath: worktree.path)?.path == worktree.path else {
                throw ChatGitWorktreeError(message: "The checkout's registration has changed. It has been preserved.")
            }
        }
        let ownedCommit = try? git(["rev-parse", "--verify", branchRef], at: worktree.repositoryPath)
        let head: ChatGitHead?
        let commit: String?
        if let checkout {
            let listedCommit = checkout.first { $0.hasPrefix("HEAD ") }.map { String($0.dropFirst(5)) }
            let listedBranch = checkout.first { $0.hasPrefix("branch refs/heads/") }
                .map { String($0.dropFirst("branch refs/heads/".count)) }
            head = listedBranch.map(ChatGitHead.branch) ?? listedCommit.flatMap { ChatGitHead(contents: $0) }
            // Always save the checked-out HEAD, which can differ from the branch Nativ created.
            commit = exists ? try git(["rev-parse", "--verify", "HEAD^{commit}"], at: worktree.path) : listedCommit
            guard let commit, head != nil,
                  (try? git(["cat-file", "-t", commit], at: worktree.repositoryPath)) == "commit",
                  !exists || (worktree.currentHead == head && commit == listedCommit) else {
                throw ChatGitWorktreeError(message: "The checkout's HEAD could not be verified. It has been preserved; try again after Git finishes.")
            }
        } else {
            // Partial setup or a retry after removing the checkout can still own a branch.
            head = ownedCommit == nil ? nil : .branch(worktree.branch)
            commit = ownedCommit
        }
        let dirty = exists ? !(try git(["status", "--porcelain=v1", "--untracked-files=all", "--ignored"], at: worktree.path)).isEmpty : false
        let ignored = exists ? try git(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], at: worktree.path)
            .split(separator: "\0").map(String.init) : []
        let unmerged = commit.map {
            // A nonzero merge-base result includes an unavailable comparison target; fail safely.
            (try? git(["merge-base", "--is-ancestor", $0, "HEAD"], at: worktree.repositoryPath)) == nil
        } ?? false
        // Never delete a user branch. Remove our original branch only if its history is in
        // the snapshot and no other checkout uses it; otherwise leave that branch intact.
        let removesBranch = !branchIsInUseElsewhere && ownedCommit.flatMap { owned in
            commit.map { (try? git(["merge-base", "--is-ancestor", owned, $0], at: worktree.repositoryPath)) != nil }
        } == true
        return ChatGitWorktreeRemoval(hasCheckout: checkout != nil, checkoutHead: head, headCommit: commit,
                                      branchCommit: ownedCommit, removesManagedBranch: removesBranch,
                                      hasUncommittedFiles: dirty, hasUnmergedCommits: unmerged, ignoredFiles: ignored)
    }

    func remove(_ worktree: ChatGitWorktree, sessionID: UUID, discardChanges: Bool = false, title: String = "Worktree",
                workState: ChatWorkState? = nil) throws {
        // Recheck immediately before cleanup; never use a stale dialog's assessment.
        let state = try removal(worktree, sessionID: sessionID)
        guard discardChanges || !state.requiresConfirmation else {
            throw ChatGitWorktreeError(message: state.warning)
        }
        // Persist and independently verify the backup before any destructive Git operation.
        let snapshot = try snapshot(worktree, sessionID: sessionID, title: title, state: state, workState: workState)
        let latest = try removal(worktree, sessionID: sessionID)
        guard latest.hasCheckout == state.hasCheckout,
              latest.checkoutHead == state.checkoutHead, latest.headCommit == state.headCommit,
              latest.branchCommit == state.branchCommit, latest.removesManagedBranch == state.removesManagedBranch,
              discardChanges || !latest.requiresConfirmation else {
            throw ChatGitWorktreeError(message: "The worktree changed while it was being saved. It has been kept; try deleting it again.")
        }
        if let snapshot, FileManager.default.fileExists(atPath: worktree.path) {
            guard try git(["write-tree"], at: worktree.path) == snapshot.indexTree,
                  try workingTree(at: worktree.path, indexTree: snapshot.indexTree) == snapshot.workingTree else {
                throw ChatGitWorktreeError(message: "Files changed while the snapshot was being saved. The checkout has been kept; try deleting it again.")
            }
        }
        if state.hasCheckout {
            var arguments = ["worktree", "remove"]
            if snapshot != nil || discardChanges { arguments.append("--force") }
            _ = try git(arguments + ["--", worktree.path], at: worktree.repositoryPath)
        }
        if state.removesManagedBranch, let commit = state.branchCommit {
            let ref = "refs/heads/\(worktree.branch)"
            let registrations = try git(["worktree", "list", "--porcelain", "-z"], at: worktree.repositoryPath)
            // A different checkout may have started using it while ours was removed.
            if !registrations.components(separatedBy: "\0").contains("branch \(ref)") {
                // Compare-and-delete refuses to erase a branch updated during cleanup.
                _ = try git(["update-ref", "-d", ref, commit], at: worktree.repositoryPath)
            }
        }
    }

    func git(_ arguments: [String], at path: String, environment extraEnvironment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // A checkout must not execute repository hooks in the background.
        process.arguments = ["-C", path, "-c", "core.hooksPath=/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.removeValue(forKey: "CFFIXED_USER_HOME")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ChatGitWorktreeError(message: text.isEmpty ? "Git could not prepare the worktree." : String(text.prefix(2_000)))
        }
        return text
    }
}
