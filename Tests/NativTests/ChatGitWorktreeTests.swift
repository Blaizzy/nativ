import Foundation
import XCTest

private struct WorktreeFixture {
    let root: URL
    let repository: URL
    var store: ChatGitWorktreeStore { .init(root: root.appendingPathComponent("Worktrees")) }

    init(commit: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        repository = root.appendingPathComponent("Project with spaces")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Self.git(["init", "-b", "main", repository.path])
        try "committed".write(to: repository.appendingPathComponent("Sources/value.txt"), atomically: true, encoding: .utf8)
        if commit {
            try Self.git(["-C", repository.path, "add", "."])
            try Self.git(["-C", repository.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false", "commit", "-m", "Initial"])
        }
    }

    @discardableResult
    static func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw ChatGitWorktreeError(message: text) }
        return text
    }
}

final class ChatGitWorktreeTests: XCTestCase {
    func testIndependentCheckoutsUseCommittedFilesAndPreserveLocalEdits() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.repository.appendingPathComponent("Sources/value.txt")
        try "local edit".write(to: original, atomically: true, encoding: .utf8)
        let first = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        let second = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertNotEqual(first.branch, second.branch)
        XCTAssertEqual(first.commonDirectory, second.commonDirectory)
        XCTAssertEqual(first.availableRootPath, first.path)
        XCTAssertEqual(try WorktreeFixture.git(["-C", first.path, "branch", "--show-current"]), first.branch)
        let firstFile = URL(fileURLWithPath: first.path).appendingPathComponent("Sources/value.txt")
        let secondFile = URL(fileURLWithPath: second.path).appendingPathComponent("Sources/value.txt")
        XCTAssertEqual(try String(contentsOf: firstFile, encoding: .utf8), "committed")
        try "first edit".write(to: firstFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: secondFile, encoding: .utf8), "committed")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "local edit")
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "main")
    }

    func testFileAccessInsideManagedAppStorageCheckoutPreservesPrivateDataProtection() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appData = fixture.root.appendingPathComponent("Library/Application Support/Nativ")
        let store = ChatGitWorktreeStore(root: appData.appendingPathComponent("Chat/Worktrees"))
        let tree = try store.create(store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        let reads = try FileReadAccessPolicy(rootPath: tree.projectPath)
        let writes = try FileWriteAccessPolicy(rootPath: tree.projectPath)
        let source = try reads.resolve(path: "Sources/value.txt").url
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "committed")
        let destination = try writes.resolve(path: "Sources/value.txt").url
        try "checkout edit".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "checkout edit")
        XCTAssertEqual(try String(contentsOf: fixture.repository.appendingPathComponent("Sources/value.txt"), encoding: .utf8), "committed")
        let nested = try FileReadAccessPolicy(rootPath: URL(fileURLWithPath: tree.path).appendingPathComponent("Sources").path)
        XCTAssertEqual(try nested.resolve(path: "value.txt").url, source)
        XCTAssertThrowsError(try reads.resolve(path: ".git"))
        XCTAssertThrowsError(try reads.resolve(path: ".env"))
        XCTAssertThrowsError(try writes.resolve(path: "id_rsa"))
        XCTAssertThrowsError(try reads.resolve(path: "../another-chat/file.txt"))
        XCTAssertThrowsError(try writes.resolve(path: "../another-chat/file.txt"))
        let privateFile = appData.appendingPathComponent("settings.json")
        try "private".write(to: privateFile, atomically: true, encoding: .utf8)
        let link = URL(fileURLWithPath: tree.path).appendingPathComponent("outside.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: privateFile)
        XCTAssertThrowsError(try reads.resolve(path: "outside.json"))
        XCTAssertThrowsError(try writes.resolve(path: "outside.json"))
        XCTAssertThrowsError(try FileReadAccessPolicy(rootPath: appData.path).resolve(path: "settings.json"))
        XCTAssertThrowsError(try FileWriteAccessPolicy(rootPath: appData.path).resolve(path: "settings.json"))
        XCTAssertThrowsError(try FileReadAccessPolicy(rootPath: fixture.root.path).resolve(path: privateFile.path))
        // A folder with the right name, but no Git registration, is still protected.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path).appendingPathComponent(".git"))
        XCTAssertThrowsError(try reads.resolve(path: "Sources/value.txt"))
        XCTAssertThrowsError(try writes.resolve(path: "Sources/value.txt"))
    }

    func testNestedProjectFromDetachedHeadAndInterruptedSetupRecovery() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try WorktreeFixture.git(["-C", fixture.repository.path, "checkout", "--detach"])
        let plan = try fixture.store.plan(projectPath: fixture.repository.appendingPathComponent("Sources").path, sessionID: UUID())
        XCTAssertEqual(plan.projectSubpath, "Sources")
        XCTAssertNil(plan.availableRootPath)
        let ready = try fixture.store.create(plan)
        XCTAssertEqual(ready.availableRootPath, URL(fileURLWithPath: ready.path).appendingPathComponent("Sources").path)
        let source = URL(fileURLWithPath: ready.projectPath).appendingPathComponent("value.txt")
        try "Keep edits".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.store.create(plan), ready)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Keep edits")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: ready.path).appendingPathComponent(".git"))
        XCTAssertNil(ready.availableRootPath)
        XCTAssertThrowsError(try fixture.store.create(plan))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Keep edits")
    }

    func testNonRepositoryAndUnbornRepositoryFailWithoutCreatingCheckout() throws {
        let fixture = try WorktreeFixture(commit: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try fixture.store.plan(projectPath: fixture.root.path, sessionID: UUID()))
        XCTAssertThrowsError(try fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.root.path))
    }

    func testSetupCanResumeAfterOnlyTheBranchWasCreated() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID())
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", plan.branch, plan.baseCommit])
        let ready = try fixture.store.create(plan)
        XCTAssertEqual(ready.branch, plan.branch)
        XCTAssertNotNil(ready.availableRootPath)
    }

    func testRemovalSavesDirtyAndUnmergedWorkAndRequiresConsentForIgnoredFiles() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for kind in ["tracked", "untracked", "ignored", "unmerged"] {
            let id = UUID()
            let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
            let directory = URL(fileURLWithPath: worktree.path)
            let file = directory.appendingPathComponent(kind == "tracked" ? "Sources/value.txt" : "generated.txt")
            try "Keep my work".write(to: file, atomically: true, encoding: .utf8)
            if kind == "ignored" {
                let exclude = fixture.repository.appendingPathComponent(".git/info/exclude")
                try "generated.txt\n".write(to: exclude, atomically: true, encoding: .utf8)
            }
            if kind == "unmerged" {
                try WorktreeFixture.git(["-C", worktree.path, "add", "-f", "."])
                try WorktreeFixture.git(["-C", worktree.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false", "commit", "-m", "Worktree work"])
            }
            let assessment = try fixture.store.removal(worktree, sessionID: id)
            XCTAssertEqual(assessment.requiresConfirmation, kind == "ignored", kind)
            XCTAssertEqual(assessment.hasUnmergedCommits, kind == "unmerged", kind)
            XCTAssertEqual(assessment.hasUncommittedFiles, kind != "unmerged", kind)
            if kind == "ignored" { XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: id)) }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Keep my work")
            try fixture.store.remove(worktree, sessionID: id, discardChanges: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
            XCTAssertThrowsError(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "--verify", "refs/heads/\(worktree.branch)"]))
            XCTAssertTrue(try fixture.store.snapshots().contains { $0.sessionID == id })
        }
        XCTAssertEqual(try String(contentsOf: fixture.repository.appendingPathComponent("Sources/value.txt"), encoding: .utf8), "committed")
    }

    func testRemovalOfMergedWorkAndPartialSetupIsRetryable() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try WorktreeFixture.git(["-C", worktree.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Completed"])
        try WorktreeFixture.git(["-C", fixture.repository.path, "merge", "--ff-only", worktree.branch])
        XCTAssertFalse(try fixture.store.removal(worktree, sessionID: id).requiresConfirmation)
        try fixture.store.remove(worktree, sessionID: id)
        try fixture.store.remove(worktree, sessionID: id)
        let pendingID = UUID()
        let pending = try fixture.store.plan(projectPath: fixture.repository.path, sessionID: pendingID)
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", pending.branch, pending.baseCommit])
        try fixture.store.remove(pending, sessionID: pendingID)
        XCTAssertThrowsError(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "--verify", "refs/heads/\(pending.branch)"]))
    }

    func testRemovalPreservesUnregisteredFoldersAndOtherBranches() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: UUID(), discardChanges: true))
        try WorktreeFixture.git(["-C", worktree.path, "switch", "-c", "other-work"])
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: id, discardChanges: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        try WorktreeFixture.git(["-C", worktree.path, "switch", worktree.branch])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: worktree.path).appendingPathComponent(".git"))
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: id, discardChanges: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testMissingCheckoutRegistrationCanBeRemoved() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: worktree.path))
        try fixture.store.remove(worktree, sessionID: id)
        XCTAssertFalse(try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "list", "--porcelain"]).contains(worktree.path))
    }

    func testBranchInAnotherCheckoutIsNotDeleted() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "remove", worktree.path])
        let other = fixture.root.appendingPathComponent("Moved checkout")
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "add", other.path, worktree.branch])
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: id, discardChanges: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try WorktreeFixture.git(["-C", other.path, "branch", "--show-current"]), worktree.branch)
    }

    func testRecoveryPreservesHistoryIndexWorkingFilesAndSurvivesGitGarbageCollection() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        let directory = URL(fileURLWithPath: tree.path)
        try "unmerged work".write(to: directory.appendingPathComponent("history.txt"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try WorktreeFixture.git(["-C", tree.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false", "commit", "-m", "Unmerged work"])
        let head = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
        let value = directory.appendingPathComponent("Sources/value.txt")
        try "staged".write(to: value, atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try "unstaged".write(to: value, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("history.txt"))
        let bytes = Data([0, 1, 255, 0, 10, 128])
        try bytes.write(to: directory.appendingPathComponent("new image.bin"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path,
                                                  withDestinationPath: "Sources/value.txt")
        let index = try WorktreeFixture.git(["-C", tree.path, "write-tree"])
        try fixture.store.remove(tree, sessionID: id, title: "Saved experiment")
        let record = try XCTUnwrap(fixture.store.snapshots().first)
        XCTAssertEqual(record.indexTree, index)
        XCTAssertEqual(record.head, head)
        XCTAssertEqual(record.title, "Saved experiment")
        try WorktreeFixture.git(["-C", fixture.repository.path, "reflog", "expire", "--expire=now", "--all"])
        try WorktreeFixture.git(["-C", fixture.repository.path, "gc", "--prune=now"])
        let store = ChatGitWorktreeStore(root: fixture.store.root)
        let plan = try store.restorationPlan(record, sessionID: UUID())
        let restored = try store.restore(record.id, to: plan)
        XCTAssertEqual(try WorktreeFixture.git(["-C", restored.path, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try WorktreeFixture.git(["-C", restored.path, "write-tree"]), index)
        XCTAssertEqual(try WorktreeFixture.git(["-C", restored.path, "show", ":Sources/value.txt"]), "staged")
        let restoredDirectory = URL(fileURLWithPath: restored.path)
        XCTAssertEqual(try String(contentsOf: restoredDirectory.appendingPathComponent("Sources/value.txt"), encoding: .utf8), "unstaged")
        XCTAssertEqual(try Data(contentsOf: restoredDirectory.appendingPathComponent("new image.bin")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredDirectory.appendingPathComponent("history.txt").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: restoredDirectory.appendingPathComponent("link").path), "Sources/value.txt")
        XCTAssertEqual(try String(contentsOf: fixture.repository.appendingPathComponent("Sources/value.txt"), encoding: .utf8), "committed")
        try store.permanentlyDeleteSnapshot(record.id)
        XCTAssertTrue(try store.snapshots().isEmpty)
        XCTAssertNotNil(restored.availableRootPath)
        XCTAssertEqual(try Data(contentsOf: restoredDirectory.appendingPathComponent("new image.bin")), bytes)
    }

    func testSnapshotFailureKeepsCheckoutBranchAndIndexUnchanged() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        let file = URL(fileURLWithPath: tree.path).appendingPathComponent("Sources/value.txt")
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try "unstaged".write(to: file, atomically: true, encoding: .utf8)
        let index = try WorktreeFixture.git(["-C", tree.path, "write-tree"])
        try "blocked".write(to: fixture.store.recoveryRoot, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.store.remove(tree, sessionID: id))
        XCTAssertEqual(try WorktreeFixture.git(["-C", tree.path, "write-tree"]), index)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged")
        XCTAssertNotNil(tree.availableRootPath)
        XCTAssertEqual(try WorktreeFixture.git(["-C", tree.path, "branch", "--show-current"]), tree.branch)
    }

    func testCorruptBundleAndOccupiedRestoreDestinationArePreserved() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try fixture.store.remove(tree, sessionID: id)
        let record = try XCTUnwrap(fixture.store.snapshots().first)
        let plan = try fixture.store.restorationPlan(record, sessionID: UUID())
        try FileManager.default.createDirectory(atPath: plan.path, withIntermediateDirectories: true)
        let occupied = URL(fileURLWithPath: plan.path).appendingPathComponent("keep.txt")
        try "Keep".write(to: occupied, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.store.restore(record.id, to: plan))
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "Keep")
        let otherPlan = try fixture.store.restorationPlan(record, sessionID: UUID())
        try "bad bundle".write(to: fixture.store.snapshotDirectory(record.id).appendingPathComponent("snapshot.bundle"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.store.restore(record.id, to: otherPlan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherPlan.path))
        XCTAssertEqual(try fixture.store.snapshots().count, 1)
    }

    func testIgnoredFilesAreListedAndExcludedAndNestedRepositoriesBlockCleanup() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        let directory = URL(fileURLWithPath: tree.path)
        try ".env\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "secret".write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try fixture.store.removal(tree, sessionID: id).ignoredFiles.contains(".env"))
        XCTAssertThrowsError(try fixture.store.remove(tree, sessionID: id))
        XCTAssertTrue(try fixture.store.snapshots().isEmpty)
        try fixture.store.remove(tree, sessionID: id, discardChanges: true)
        let record = try XCTUnwrap(fixture.store.snapshots().first)
        XCTAssertEqual(record.ignoredFiles, [".env"])
        let restored = try fixture.store.restore(record.id, to: fixture.store.restorationPlan(record, sessionID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: restored.path).appendingPathComponent(".env").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: restored.path).appendingPathComponent(".gitignore").path))
        let nested = URL(fileURLWithPath: restored.path).appendingPathComponent("nested")
        try WorktreeFixture.git(["clone", fixture.repository.path, nested.path])
        let restoredID = try XCTUnwrap(UUID(uuidString: URL(fileURLWithPath: restored.path).lastPathComponent))
        XCTAssertThrowsError(try fixture.store.remove(restored, sessionID: restoredID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}

@MainActor
final class ChatWorktreeSessionTests: XCTestCase {
    func testSetupLocksOtherWindowsAndFinishesInTheOriginalChatAfterNavigation() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let activity = InferenceActivityCoordinator()
        let changes = PersistedDataChangeHub()
        let first = ChatViewModel(persistedDataChanges: changes, inferenceActivity: activity,
                                  projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(first)
        first.createSession(projectID: project.id)
        let id = try XCTUnwrap(first.currentSessionID)
        let second = ChatViewModel(persistedDataChanges: changes, inferenceActivity: activity,
                                   projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(second)
        second.selectSession(id)
        first.draft = "A pending request"
        let setup = Task { try await first.createCurrentWorktree() }
        for _ in 0..<100 where !first.isPreparingCurrentWorktree { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(first.isPreparingCurrentWorktree)
        XCTAssertFalse(first.canSend(isRunning: true, selectedModelID: "model"))
        XCTAssertFalse(second.canCreateCurrentWorktree)
        XCTAssertFalse(second.canModifySession(id))
        first.createSession()
        let newID = first.currentSessionID
        try await setup.value
        XCTAssertEqual(first.currentSessionID, newID)
        XCTAssertNil(first.currentWorktree)
        first.selectSession(id)
        XCTAssertTrue(first.currentWorktree?.isReady == true)
        XCTAssertTrue(second.canModifySession(id))
        XCTAssertEqual(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id)?.worktree, first.currentWorktree)
    }

    func testRoutingPersistsAndEmptyWorktreeChatsAreNotReusedOrPruned() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let firstID = try XCTUnwrap(chat.currentSessionID)
        try await chat.createCurrentWorktree()
        let first = try XCTUnwrap(chat.currentWorktree)
        var settings = NativSettings()
        settings.projectToolsEnabled = true
        let scope = chat.toolScope(for: firstID, settings: settings)
        XCTAssertEqual(scope.fileReadRootPath, first.path)
        XCTAssertEqual(scope.fileWriteRootPath, first.path)
        XCTAssertEqual(scope.terminalWorkingDirectory, first.path)
        XCTAssertTrue(scope.projectToolsAreAvailable)
        XCTAssertTrue(scope.systemPrompt?.contains(first.branch) == true)
        chat.createSession(projectID: project.id)
        XCTAssertNotEqual(chat.currentSessionID, firstID)
        XCTAssertNil(chat.currentWorktree)
        XCTAssertEqual(chat.toolScope(for: try XCTUnwrap(chat.currentSessionID), settings: settings).rootPath, project.rootPath)
        try await chat.createCurrentWorktree()
        XCTAssertNotEqual(chat.currentWorktree?.path, first.path)
        XCTAssertEqual(chat.toolScope(for: firstID, settings: settings), scope)
        let restored = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(restored)
        restored.selectSession(firstID)
        XCTAssertEqual(restored.currentWorktree, first)
        XCTAssertEqual(restored.toolScope(for: firstID, settings: settings), scope)
        XCTAssertTrue(restored.sessions.contains { $0.id == firstID && $0.worktree == first })
        try restored.createWorkItem(title: "Terminal", kind: .terminal)
        let terminal = restored.workTerminal(for: try XCTUnwrap(restored.workState.selectedItem), sessionID: firstID)
        XCTAssertEqual(terminal.directory, first.path)
        // Deleting a clean chat removes only its dedicated checkout and branch.
        try await restored.deleteSession(firstID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertThrowsError(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "--verify", "refs/heads/\(first.branch)"]))
    }

    func testMissingCheckoutCannotFallBackToLocalOrStandaloneRoots() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.root.appendingPathComponent("Chat"))
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        try await chat.createCurrentWorktree()
        let reference = try XCTUnwrap(chat.currentWorktree)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: reference.path))
        var settings = NativSettings()
        settings.projectToolsEnabled = true
        settings.fileReadRootPath = fixture.repository.path
        settings.fileWriteRootPath = fixture.repository.path
        let scope = chat.toolScope(for: try XCTUnwrap(chat.currentSessionID), settings: settings)
        XCTAssertTrue(scope.isProject)
        XCTAssertNil(scope.fileReadRootPath)
        XCTAssertNil(scope.fileWriteRootPath)
        XCTAssertFalse(scope.projectToolsAreAvailable)
        XCTAssertEqual(scope.terminalWorkingDirectory, reference.path)
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        let terminal = chat.workTerminal(for: try XCTUnwrap(chat.workState.selectedItem), sessionID: try XCTUnwrap(chat.currentSessionID))
        terminal.startIfNeeded(shell: "/bin/zsh", arguments: ["-f"])
        XCTAssertFalse(terminal.isRunning)
        XCTAssertEqual(terminal.status, "Folder unavailable")
        // Detaching from a removed project also retains the checkout association.
        let kept = try await chat.removeProjectSessions(projectID: project.id, disposition: .keepChats)
        XCTAssertTrue(kept)
        let detached = chat.toolScope(for: try XCTUnwrap(chat.currentSessionID), settings: settings)
        XCTAssertTrue(detached.isProject)
        XCTAssertNil(detached.rootPath)
    }

    func testFailedSetupPreservesReservationAndDoesNotOverwriteExistingFiles() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let id = try XCTUnwrap(chat.currentSessionID)
        let path = chatRoot.appendingPathComponent("Worktrees/\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let existing = path.appendingPathComponent("keep.txt")
        try "Keep me".write(to: existing, atomically: true, encoding: .utf8)
        do { try await chat.createCurrentWorktree(); XCTFail("Expected checkout conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already exists")) }
        XCTAssertEqual(chat.currentWorktree?.isReady, false)
        XCTAssertFalse(chat.isPreparingCurrentWorktree)
        XCTAssertTrue(chat.canCreateCurrentWorktree)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Keep me")
        XCTAssertEqual(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id)?.worktree, chat.currentWorktree)
    }

    func testDeletionCancelKeepsChatAndConsentRemovesCheckoutAndBranch() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let activity = InferenceActivityCoordinator()
        let chat = ChatViewModel(inferenceActivity: activity, projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let id = try XCTUnwrap(chat.currentSessionID)
        try await chat.createCurrentWorktree()
        let worktree = try XCTUnwrap(chat.currentWorktree)
        let file = URL(fileURLWithPath: worktree.path).appendingPathComponent("keep.txt")
        try "Keep me".write(to: file, atomically: true, encoding: .utf8)
        try "keep.txt\n".write(to: fixture.repository.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let canceled = try await chat.deleteSession(id) { warning in
            XCTAssertTrue(warning.contains("ignored"))
            XCTAssertFalse(chat.canModifySession(id))
            XCTAssertTrue(chat.isDeletingCurrentSession)
            XCTAssertFalse(chat.canSend(isRunning: true, selectedModelID: "model"))
            return false
        }
        XCTAssertFalse(canceled)
        XCTAssertNotNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Keep me")
        XCTAssertTrue(chat.canModifySession(id))
        let removed = try await chat.deleteSession(id) { _ in true }
        XCTAssertTrue(removed)
        XCTAssertNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertFalse(activity.hasActiveOperations)
    }

    func testCleanupFailureKeepsChatForRetryAndProjectKeepChatsKeepsCheckout() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let id = try XCTUnwrap(chat.currentSessionID)
        try await chat.createCurrentWorktree()
        let worktree = try XCTUnwrap(chat.currentWorktree)
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "lock", worktree.path])
        do { try await chat.deleteSession(id); XCTFail("Locked checkout must be preserved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("locked")) }
        XCTAssertTrue(chat.canModifySession(id))
        XCTAssertNotNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        let kept = try await chat.removeProjectSessions(projectID: project.id, disposition: .keepChats)
        XCTAssertTrue(kept)
        XCTAssertEqual(chat.currentWorktree, worktree)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "unlock", worktree.path])
        try await chat.deleteSession(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testDeletingProjectChatsCleansAllManagedWorktrees() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.root.appendingPathComponent("Chat"))
        try await loaded(chat)
        var checkouts: [ChatGitWorktree] = []
        for _ in 0..<2 {
            chat.createSession(projectID: project.id)
            try await chat.createCurrentWorktree()
            checkouts.append(try XCTUnwrap(chat.currentWorktree))
        }
        let removed = try await chat.removeProjectSessions(projectID: project.id, disposition: .deleteChats)
        XCTAssertTrue(removed)
        XCTAssertFalse(chat.sessions.contains { $0.projectID == project.id })
        for checkout in checkouts { XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repository.path))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "main")
    }

    func testDeletedChatCanRestoreWorkInANewChatAfterRestart() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let oldID = try XCTUnwrap(chat.currentSessionID)
        try await chat.createCurrentWorktree()
        let oldTree = try XCTUnwrap(chat.currentWorktree)
        try "Recovery content".write(to: URL(fileURLWithPath: oldTree.path).appendingPathComponent("draft.txt"),
                                     atomically: true, encoding: .utf8)
        let removed = try await chat.deleteSession(oldID)
        XCTAssertTrue(removed)
        XCTAssertNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: oldID))
        let restarted = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(restarted)
        let record = try XCTUnwrap(restarted.worktreeRecoveryStore.snapshots().first)
        let newID = try await restarted.restoreWorktreeSnapshot(record.id)
        XCTAssertNotEqual(oldID, newID)
        restarted.selectSession(newID)
        let restored = try XCTUnwrap(restarted.currentWorktree)
        XCTAssertNotEqual(restored.path, oldTree.path)
        XCTAssertEqual(restarted.currentProjectID, project.id)
        XCTAssertTrue(restarted.messages.isEmpty)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: restored.path).appendingPathComponent("draft.txt"), encoding: .utf8), "Recovery content")
        XCTAssertEqual(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: newID)?.worktree, restored)
        XCTAssertEqual(restarted.toolScope(for: newID, settings: NativSettings()).rootPath, restored.projectPath)
        try await restarted.permanentlyDeleteWorktreeSnapshot(record.id)
        XCTAssertTrue(try restarted.worktreeRecoveryStore.snapshots().isEmpty)
        XCTAssertNotNil(restored.availableRootPath)
    }

    func testSnapshotPersistenceFailureKeepsChatAndWorktree() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let id = try XCTUnwrap(chat.currentSessionID)
        try await chat.createCurrentWorktree()
        let tree = try XCTUnwrap(chat.currentWorktree)
        try "blocked".write(to: chat.worktreeRecoveryStore.recoveryRoot, atomically: true, encoding: .utf8)
        do { try await chat.deleteSession(id); XCTFail("Cannot delete without a verified snapshot") }
        catch { }
        XCTAssertNotNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id))
        XCTAssertNotNil(tree.availableRootPath)
        XCTAssertTrue(chat.canModifySession(id))
        XCTAssertFalse(chat.isDeletingCurrentSession)
    }

    private func loaded(_ chat: ChatViewModel) async throws {
        for _ in 0..<100 where chat.isLoadingSessions { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(chat.isLoadingSessions)
    }
}
