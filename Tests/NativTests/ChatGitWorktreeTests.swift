import Foundation
import XCTest

final class ChatGitHubPullRequestTests: XCTestCase {
    private func output(_ text: String = "", error: String = "", code: Int32 = 0,
                        timedOut: Bool = false, truncated: Bool = false) -> TerminalProcessResult {
        .init(stdout: text, stderr: error, exitCode: code, terminationSignal: nil, timedOut: timedOut,
              durationMilliseconds: 0, outputTruncated: truncated)
    }

    func testPRStatesAndBranchIdentity() throws {
        for (state, draft, label) in [("OPEN", false, "Open"), ("OPEN", true, "Draft"),
                                      ("MERGED", false, "Merged"), ("CLOSED", false, "Closed")] {
            let json = """
            {"number":656,"title":"Worktrees","url":"https://github.com/Blaizzy/nativ/pull/656",
             "state":"\(state)","isDraft":\(draft),"headRefName":"123"}
            """
            guard case .found(let request) = ChatGitHubPullRequestDetector.decode(output(json), branch: "123") else {
                return XCTFail("Expected matching PR")
            }
            XCTAssertEqual(request.status, label)
            XCTAssertEqual(ChatGitHubPullRequestDetector.decode(output(json), branch: "other"), .notFound)
            XCTAssertEqual(ChatGitHubPullRequestDetector.decode(output(json), branch: "local", upstreamBranch: "123"), .found(request))
            for invalid in [json.replacingOccurrences(of: "https://", with: "file:///"), "not json"] {
                guard case .unavailable = ChatGitHubPullRequestDetector.decode(output(invalid), branch: "123") else {
                    return XCTFail("Invalid PR data must not create a clickable link")
                }
            }
        }
    }

    func testNoPRIsDistinctFromAuthenticationAndLookupFailures() {
        let none = output(error: "no pull requests found for branch \"main\"\n", code: 1)
        XCTAssertEqual(ChatGitHubPullRequestDetector.decode(none, branch: "main"), .notFound)
        for failure in [output(code: 4), output(error: "please run gh auth login", code: 1),
                        output(code: 127), output(error: "network error", code: 1),
                        output(timedOut: true), output(truncated: true)] {
            guard case .unavailable = ChatGitHubPullRequestDetector.decode(failure, branch: "main") else {
                return XCTFail("Lookup errors must not be reported as no PR")
            }
        }
    }

    func testLookupUsesCheckoutWithoutInterpolatingBranchOrStartingInteractiveAuth() async throws {
        let response = output(error: "no pull requests found for branch \"123\"\n", code: 1)
        let result = try await ChatGitHubPullRequestDetector.lookup(at: "/tmp/project with spaces", branch: "123") { request in
            XCTAssertEqual(request.command, "exec gh pr view --json number,title,url,state,isDraft,headRefName")
            XCTAssertEqual(request.currentDirectoryURL.path, "/tmp/project with spaces")
            XCTAssertEqual(request.environment["GH_PROMPT_DISABLED"], "1")
            XCTAssertNil(request.environment["GH_REPO"])
            XCTAssertNil(request.environment["GIT_DIR"])
            XCTAssertEqual(request.timeout, 15)
            return response
        }
        XCTAssertEqual(result, .notFound)
    }
}

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
    @MainActor
    func testGitChangeObserverSeesNestedEditsAndWorktreeBranchChangesAndStops() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.appendingPathComponent("Sources").path, sessionID: UUID()))
        let paths = try fixture.store.observationPaths(at: tree.projectPath)
        let canonical = { (path: String) in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(Set(paths.map(canonical)), Set([tree.path, tree.commonDirectory].map(canonical)))

        let edited = expectation(description: "Nested file changed")
        edited.assertForOverFulfill = false
        let observer = try XCTUnwrap(ChatGitChangeObserver(paths: paths) { edited.fulfill() })
        try "edited\n".write(to: URL(fileURLWithPath: tree.projectPath).appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        await fulfillment(of: [edited], timeout: 5)
        observer.stop()
        observer.stop() // Cancellation and deinit can both stop the same observer.

        let renamed = expectation(description: "Worktree Git metadata changed")
        renamed.assertForOverFulfill = false
        let metadataObserver = try XCTUnwrap(ChatGitChangeObserver(paths: paths) { renamed.fulfill() })
        try WorktreeFixture.git(["-C", tree.path, "branch", "-m", "renamed-branch"])
        await fulfillment(of: [renamed], timeout: 5)
        XCTAssertEqual(tree.currentHead, .branch("renamed-branch"))
        metadataObserver.stop()

        let stopped = expectation(description: "Stopped observer stays silent")
        stopped.isInverted = true
        let stoppedObserver = try XCTUnwrap(ChatGitChangeObserver(paths: paths) { stopped.fulfill() })
        stoppedObserver.stop()
        try "later\n".write(to: URL(fileURLWithPath: tree.projectPath).appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testDiffCounterIncludesBranchAndUncommittedChangesWithoutChangingTheIndex() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let commit = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false", "commit", "-m", "Changes"]
        try "old\nrows\n".write(to: fixture.repository.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: fixture.repository.appendingPathComponent("rename.txt"), atomically: true, encoding: .utf8)
        try "ignored.txt\n".write(to: fixture.repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", fixture.repository.path, "add", "."])
        try WorktreeFixture.git(["-C", fixture.repository.path] + commit)
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.appendingPathComponent("Sources").path, sessionID: UUID()))
        let root = URL(fileURLWithPath: tree.path)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.projectPath, baseCommit: tree.baseCommit), ChatGitDiffStat())
        let value = root.appendingPathComponent("Sources/value.txt")
        try "first\nsecond\n".write(to: value, atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try WorktreeFixture.git(["-C", tree.path] + commit)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.path), ChatGitDiffStat(additions: 2, deletions: 1))
        try "first\nstaged\n".write(to: value, atomically: true, encoding: .utf8)
        try "staged\n".write(to: root.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try WorktreeFixture.git(["-C", tree.path, "mv", "rename.txt", "renamed.txt"])
        try "first\nfinal\nthird\n".write(to: value, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        try "new\nlast line".write(to: root.appendingPathComponent("\tNew\nfile.txt"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: root.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin"))
        let index = try WorktreeFixture.git(["-C", tree.path, "ls-files", "--stage"])
        let expected = ChatGitDiffStat(additions: 6, deletions: 3)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.projectPath, baseCommit: tree.baseCommit), expected)
        XCTAssertEqual(try WorktreeFixture.git(["-C", tree.path, "ls-files", "--stage"]), index)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try WorktreeFixture.git(["-C", tree.path] + commit)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.path, baseCommit: tree.baseCommit), expected)
        XCTAssertThrowsError(try fixture.store.diffStat(at: fixture.root.path))
    }

    func testRandomFallbackPreservesValidNamesAndExcludesOccupiedNames() throws {
        let all = Set(ChatGitWorktreeStore.fallbackBranches)
        let available = "nativ/quiet-cedar"
        let occupied = all.subtracting([available])
        XCTAssertEqual(try ChatGitWorktreeStore.availableBranch("fix-login", excluding: occupied), "nativ/fix-login")
        for response in [nil, "", "../../main", "Here is the branch: fix-login", String(repeating: "x", count: 61), "quiet-cloud"] {
            XCTAssertEqual(try ChatGitWorktreeStore.availableBranch(response, excluding: occupied), available)
        }
        XCTAssertThrowsError(try ChatGitWorktreeStore.availableBranch(nil, excluding: all))
    }

    func testNamedBranchHasNoSessionSuffixAndPreservesExistingBranches() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        var plan = try fixture.store.plan(projectPath: fixture.repository.path, sessionID: id)
        plan.branch = try ChatGitWorktreeStore.namedBranch("`Fix-Login-Flow`")
        XCTAssertEqual(plan.branch, "nativ/fix-login-flow")
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", plan.branch])
        XCTAssertFalse(fixture.store.hasStartedCreating(plan))
        XCTAssertThrowsError(try fixture.store.create(plan))
        XCTAssertFalse(try fixture.store.removal(plan, sessionID: id).removesManagedBranch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.path))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", plan.branch]), plan.baseCommit)
    }

    func testSyncUsesFreshRemoteDefaultBranchWithoutChangingLocalCheckout() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "-m", "trunk"])
        let remote = fixture.root.appendingPathComponent("remote.git")
        try WorktreeFixture.git(["clone", "--bare", fixture.repository.path, remote.path])
        try WorktreeFixture.git(["-C", fixture.repository.path, "remote", "add", "origin", remote.path])
        let writer = fixture.root.appendingPathComponent("writer")
        try WorktreeFixture.git(["clone", remote.path, writer.path])
        try "remote update".write(to: writer.appendingPathComponent("Sources/value.txt"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", writer.path, "add", "."])
        try WorktreeFixture.git(["-C", writer.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgSign=false", "commit", "-m", "Remote update"])
        try WorktreeFixture.git(["-C", writer.path, "push", "origin", "trunk"])
        try WorktreeFixture.git(["-C", fixture.repository.path, "switch", "-c", "local-feature"])
        let localHead = try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "HEAD"])
        let localFile = fixture.repository.appendingPathComponent("Sources/value.txt")
        try "local edits".write(to: localFile, atomically: true, encoding: .utf8)
        let id = UUID()
        var synced = try fixture.store.synchronized(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        XCTAssertEqual(synced.source, "origin/trunk")
        XCTAssertEqual(synced.plan.baseCommit, try WorktreeFixture.git(["-C", writer.path, "rev-parse", "HEAD"]))
        synced.plan.branch = try ChatGitWorktreeStore.namedBranch("fix-login-flow")
        let ready = try fixture.store.create(synced.plan)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: ready.path).appendingPathComponent("Sources/value.txt"), encoding: .utf8), "remote update")
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), "local edits")
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "HEAD"]), localHead)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "local-feature")
        try fixture.store.remove(ready, sessionID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path))
        for invalid in ["", "../../main", "fix; rm -rf /", "Here is the branch: fix-login", "fix\nlogin", "fix--login"] {
            XCTAssertThrowsError(try ChatGitWorktreeStore.namedBranch(invalid))
        }
    }

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

    func testRemovalPreservesUnregisteredFolders() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: UUID(), discardChanges: true))
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
        try fixture.store.remove(worktree, sessionID: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try WorktreeFixture.git(["-C", other.path, "branch", "--show-current"]), worktree.branch)
    }

    func testLiveHeadAndCapturedAgentScopeFollowBranchSwitchRenameAndDetach() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        // A queued request keeps its scope value across model/tool rounds. Its prompt must still
        // read live HEAD rather than caching the original branch or needing a session reload.
        let scope = ChatToolScope(projectID: UUID(), projectName: "Project", rootPath: tree.path,
                                  projectToolsEnabled: true, worktree: tree)
        XCTAssertEqual(tree.currentHead, .branch(tree.branch))
        XCTAssertTrue(scope.systemPrompt?.contains("Current branch: \(tree.branch).") == true)
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature/live"])
        XCTAssertEqual(tree.currentHead, .branch("feature/live"))
        XCTAssertTrue(scope.systemPrompt?.contains("Current branch: feature/live.") == true)
        XCTAssertFalse(scope.systemPrompt?.contains(tree.branch) == true)
        try WorktreeFixture.git(["-C", tree.path, "branch", "-m", "feature/renamed"])
        let reloaded = try JSONDecoder().decode(ChatGitWorktree.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(reloaded.currentHead, .branch("feature/renamed"))
        XCTAssertEqual(try fixture.store.currentHead(at: tree.path), reloaded.currentHead)
        XCTAssertTrue(scope.systemPrompt?.contains("Current branch: feature/renamed.") == true)
        try WorktreeFixture.git(["-C", tree.path, "switch", "--detach"])
        XCTAssertEqual(tree.currentHead, .detached(tree.baseCommit))
        XCTAssertEqual(tree.currentHead?.displayName, "Detached HEAD · \(tree.baseCommit.prefix(8))")
        XCTAssertTrue(scope.systemPrompt?.contains("HEAD is detached at \(tree.baseCommit)") == true)
        XCTAssertFalse(scope.systemPrompt?.contains("Current branch:") == true)
        XCTAssertNotNil(tree.availableRootPath)
        try WorktreeFixture.git(["-C", tree.path, "switch", tree.branch])
        XCTAssertTrue(scope.systemPrompt?.contains("Current branch: \(tree.branch).") == true)
        // Local project controls use the same HEAD representation.
        XCTAssertEqual(try fixture.store.currentHead(at: fixture.repository.path), .branch("main"))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path).appendingPathComponent(".git"))
        XCTAssertNil(tree.currentHead)
        XCTAssertTrue(scope.systemPrompt?.contains("Git HEAD is unavailable") == true)
    }

    func testSwitchedRenamedAndDetachedCheckoutsSnapshotTheirActualHead() throws {
        for kind in ["new", "existing", "renamed", "detached"] {
            let fixture = try WorktreeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let id = UUID()
            let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
            switch kind {
            case "new": try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature"])
            case "existing":
                try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "feature"])
                try WorktreeFixture.git(["-C", tree.path, "switch", "feature"])
            case "renamed": try WorktreeFixture.git(["-C", tree.path, "branch", "-m", "feature"])
            default: try WorktreeFixture.git(["-C", tree.path, "switch", "--detach"])
            }
            try WorktreeFixture.git(["-C", tree.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                     "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "New HEAD"])
            let head = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
            XCTAssertNotEqual(head, tree.baseCommit)
            let expectedHead: ChatGitHead = kind == "detached" ? .detached(head) : .branch("feature")
            let file = URL(fileURLWithPath: tree.path).appendingPathComponent("Sources/value.txt")
            try "staged edit".write(to: file, atomically: true, encoding: .utf8)
            try WorktreeFixture.git(["-C", tree.path, "add", "."])
            let index = try WorktreeFixture.git(["-C", tree.path, "write-tree"])
            try "unstaged edit".write(to: file, atomically: true, encoding: .utf8)
            let state = try fixture.store.removal(tree, sessionID: id)
            XCTAssertEqual(state.checkoutHead, expectedHead, kind)
            XCTAssertEqual(state.headCommit, head, kind)
            try fixture.store.remove(tree, sessionID: id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path), kind)
            let snapshot = try XCTUnwrap(fixture.store.snapshots().first)
            XCTAssertEqual(snapshot.head, head, kind)
            XCTAssertEqual(snapshot.checkoutHead, expectedHead, kind)
            XCTAssertEqual(snapshot.indexTree, index, kind)
            if kind != "detached" {
                XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/feature"]), head)
            }
            XCTAssertThrowsError(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "--verify", "refs/heads/\(tree.branch)"]))
            // In particular, detached history must survive after the checkout and reflog are gone.
            try WorktreeFixture.git(["-C", fixture.repository.path, "reflog", "expire", "--expire=now", "--all"])
            try WorktreeFixture.git(["-C", fixture.repository.path, "gc", "--prune=now"])
            let restored = try fixture.store.restore(snapshot.id, to: fixture.store.restorationPlan(snapshot, sessionID: UUID()))
            XCTAssertEqual(try WorktreeFixture.git(["-C", restored.path, "rev-parse", "HEAD"]), head)
            XCTAssertEqual(try WorktreeFixture.git(["-C", restored.path, "write-tree"]), index)
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: restored.path).appendingPathComponent("Sources/value.txt"), encoding: .utf8), "unstaged edit")
            XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "main")
        }
    }

    func testSwitchedCheckoutKeepsOriginalBranchWhenItsHistoryIsNotInTheSnapshot() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try WorktreeFixture.git(["-C", tree.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Original branch work"])
        let originalHead = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "other", tree.baseCommit])
        XCTAssertFalse(try fixture.store.removal(tree, sessionID: id).removesManagedBranch)
        try fixture.store.remove(tree, sessionID: id)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/\(tree.branch)"]), originalHead)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/other"]), tree.baseCommit)
        XCTAssertEqual(try fixture.store.snapshots().first?.head, tree.baseCommit)
    }

    func testSwitchedCheckoutDeletionKeepsManagedBranchUsedByAnotherCheckout() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature"])
        let other = fixture.root.appendingPathComponent("Other checkout")
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "add", other.path, tree.branch])
        try fixture.store.remove(tree, sessionID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(try WorktreeFixture.git(["-C", other.path, "branch", "--show-current"]), tree.branch)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/feature"]), tree.baseCommit)
    }

    func testMissingSwitchedCheckoutStillSavesItsRecordedHead() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature"])
        try WorktreeFixture.git(["-C", tree.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "Keep feature"])
        let head = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path))
        try fixture.store.remove(tree, sessionID: id)
        let snapshot = try XCTUnwrap(fixture.store.snapshots().first)
        XCTAssertEqual(snapshot.head, head)
        XCTAssertEqual(snapshot.checkoutHead, .branch("feature"))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/feature"]), head)
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
    func testProjectPickerPreservesDraftAndReplansOnlyUncreatedWorktrees() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let first = try projects.createProject(directoryURL: fixture.repository)
        let other = fixture.root.appendingPathComponent("Other")
        try WorktreeFixture.git(["clone", fixture.repository.path, other.path])
        let second = try projects.createProject(directoryURL: other)
        let nongit = try projects.createProject(directoryURL: fixture.root)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        let id = try XCTUnwrap(chat.currentSessionID)
        chat.draft = "Keep this draft"
        let attachment = ChatImageAttachment(filename: "notes.txt", mimeType: "text/plain", base64Data: Data("Notes".utf8).base64EncodedString())
        chat.stageAttachment(attachment)
        XCTAssertTrue(chat.canChangeCurrentProject)
        try await chat.setCurrentProject(first.id)
        try await chat.setCurrentWorktreeEnabled(true)
        let pending = chat.currentWorktree
        do { try await chat.setCurrentProject(nongit.id); XCTFail("Cannot replan a worktree outside Git") }
        catch { }
        XCTAssertEqual(chat.currentProjectID, first.id)
        XCTAssertEqual(chat.currentWorktree, pending)
        try await chat.setCurrentProject(second.id)
        XCTAssertEqual(chat.currentSessionID, id)
        XCTAssertEqual(chat.currentProjectID, second.id)
        XCTAssertEqual(chat.currentWorktree?.repositoryPath, second.rootPath)
        XCTAssertEqual(chat.currentWorktree?.isReady, false)
        XCTAssertEqual(chat.draft, "Keep this draft")
        XCTAssertEqual(chat.pendingImageAttachments.map(\.id), [attachment.id])
        let saved = try XCTUnwrap(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id))
        XCTAssertEqual(saved.projectID, second.id)
        XCTAssertEqual(saved.worktree, chat.currentWorktree)
        try await chat.setCurrentProject(nil)
        XCTAssertNil(chat.currentProjectID)
        XCTAssertNil(chat.currentWorktree)
        XCTAssertNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id)?.projectID)
        XCTAssertTrue(chat.canChangeCurrentProject)
        XCTAssertFalse(chat.canChangeCurrentWorktree)
        XCTAssertFalse(chat.toolScope(for: id, settings: NativSettings()).isProject)
        do { try await chat.setCurrentProject(UUID()); XCTFail("Cannot choose a missing project") }
        catch { XCTAssertEqual(error as? ChatProjectStoreError, .projectNotFound) }
        XCTAssertNil(chat.currentProjectID)
        try chat.createWorkItem(title: "Notes.md", kind: .document, content: "Saved work")
        XCTAssertFalse(chat.canChangeCurrentProject)
        do { try await chat.setCurrentProject(first.id); XCTFail("Cannot move chat files to another project") }
        catch { }
        XCTAssertNil(chat.currentProjectID)
    }

    func testNamingErrorsInvalidResponsesAndCollisionsUseRandomBranches() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.root.appendingPathComponent("Chat"))
        try await loaded(chat)
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "nativ/fix-login"])
        let original = try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "nativ/fix-login"])
        var names = Set<String>()
        for response in [nil, "", String(repeating: "x", count: 61), "fix-login"] {
            chat.createSession(projectID: project.id)
            try await chat.setCurrentWorktreeEnabled(true)
            let id = try XCTUnwrap(chat.currentSessionID)
            try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in
                guard let response else { throw URLError(.timedOut) }
                return response
            }
            let ready = try XCTUnwrap(chat.currentWorktree)
            XCTAssertTrue(ready.isReady)
            XCTAssertNotNil(ready.branch.range(of: "^nativ/[a-z]+-[a-z]+$", options: .regularExpression))
            XCTAssertTrue(names.insert(ready.branch).inserted)
            XCTAssertEqual(try WorktreeFixture.git(["-C", ready.path, "branch", "--show-current"]), ready.branch)
            XCTAssertEqual(ChatSessionStore(chatDirectory: fixture.root.appendingPathComponent("Chat")).loadSession(id: id)?.worktree, ready)
        }
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "nativ/fix-login"]), original)
    }

    func testFirstPromptPreparationPersistsSelectionAndFinishesInOriginalChat() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let original = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(original)
        original.createSession(projectID: project.id)
        try await original.setCurrentWorktreeEnabled(true)
        let id = try XCTUnwrap(original.currentSessionID)
        let pending = try XCTUnwrap(original.currentWorktree)
        XCTAssertFalse(pending.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        original.draft = "Keep this draft"
        try await original.setCurrentWorktreeEnabled(false)
        XCTAssertNil(original.currentWorktree)
        XCTAssertNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id)?.worktree)
        XCTAssertEqual(original.draft, "Keep this draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        try await original.setCurrentWorktreeEnabled(true)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.selectSession(id)
        XCTAssertEqual(chat.currentWorktree, pending)
        try await chat.prepareWorktree(in: id, firstPrompt: "Fix the login button") { prompt in
            XCTAssertEqual(prompt, "Fix the login button")
            XCTAssertEqual(chat.currentWorktreeSetupProgress?.step, .name)
            XCTAssertEqual(chat.currentWorktreeSetupProgress?.source, "No remote · Using local commit")
            XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
            XCTAssertTrue(chat.isPreparingCurrentWorktree)
            chat.createSession()
            return "fix-login-button"
        }
        XCTAssertNil(chat.currentWorktree)
        XCTAssertNil(chat.currentWorktreeSetupProgress)
        chat.selectSession(id)
        let ready = try XCTUnwrap(chat.currentWorktree)
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.branch, "nativ/fix-login-button")
        XCTAssertEqual(chat.currentWorktreeSetupProgress?.isComplete, true)
        XCTAssertEqual(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id)?.worktree, ready)
        var settings = NativSettings()
        settings.projectToolsEnabled = true
        XCTAssertEqual(chat.toolScope(for: id, settings: settings).terminalWorkingDirectory, ready.path)
        try await chat.prepareWorktree(in: id, firstPrompt: "Another prompt") { _ in
            XCTFail("Existing worktrees must never sync or be renamed again")
            return "another-name"
        }
        XCTAssertEqual(chat.currentWorktree, ready)
        XCTAssertFalse(chat.canChangeCurrentWorktree)
        XCTAssertFalse(chat.canChangeCurrentProject)
        do { try await chat.setCurrentWorktreeEnabled(false); XCTFail("Cannot detach an existing checkout") }
        catch { }
        do { try await chat.setCurrentProject(nil); XCTFail("Cannot detach an existing checkout from its project") }
        catch { }
        XCTAssertEqual(chat.currentWorktree, ready)
        XCTAssertNotNil(ready.availableRootPath)
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertNil(chat.currentWorktreeSetupProgress)
    }

    func testDocumentsAndTerminalsWorkBeforeSetupAndDocumentsMigrateWhenReady() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository.appendingPathComponent("Sources"))
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let store = ChatSessionStore(chatDirectory: chatRoot)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let id = try XCTUnwrap(chat.currentSessionID)
        try chat.createWorkItem(title: "Notes.md", kind: .document, content: "Original")
        let document = try XCTUnwrap(chat.workState.selectedItem)
        let stagedFile = try XCTUnwrap(chat.workFileURL(for: document))
        try await chat.setCurrentWorktreeEnabled(true)
        let pending = try XCTUnwrap(chat.currentWorktree)
        chat.setWorkPaneVisible(true)
        chat.openWorkNewTab()
        try chat.refreshWorkFiles()
        XCTAssertEqual(chat.workFilesDirectory, store.workFiles.directory(for: id))
        try chat.updateWorkItem(document.id, content: "Edited", previousContent: "Original")
        XCTAssertEqual(try String(contentsOf: stagedFile, encoding: .utf8), "Edited")
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        var terminalItem = try XCTUnwrap(chat.workState.selectedItem)
        XCTAssertEqual(terminalItem.terminalWorkingDirectory, project.rootPath)
        terminalItem.terminalWorkingDirectory = pending.projectPath // Tab saved by an older build.
        let terminal = chat.workTerminal(for: terminalItem, sessionID: id)
        terminal.startIfNeeded(arguments: ["-f"])
        defer { terminal.stop() }
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(terminal.directory, project.rootPath)
        try await chat.setCurrentWorktreeEnabled(false)
        try await chat.setCurrentWorktreeEnabled(true)
        do {
            try await chat.prepareWorktree(in: id, firstPrompt: "Edit notes") { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(chat.workFileURL(for: document), stagedFile)
        try await chat.prepareWorktree(in: id, firstPrompt: "Edit notes") { _ in
            try "Edited during setup".write(to: stagedFile, atomically: true, encoding: .utf8)
            return "edit-notes"
        }
        let ready = try XCTUnwrap(chat.currentWorktree)
        let migrated = try XCTUnwrap(chat.workState.items.first { $0.id == document.id })
        let file = try XCTUnwrap(chat.workFileURL(for: migrated))
        XCTAssertTrue(file.path.hasPrefix(ready.projectPath + "/Nativ Files/"))
        XCTAssertEqual(migrated.content, "Edited during setup")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), migrated.content)
        XCTAssertEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        XCTAssertTrue(chat.workTerminal(for: terminalItem, sessionID: id) === terminal)
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(terminal.directory, project.rootPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.rootPath).appendingPathComponent("Nativ Files").path))
        try chat.createWorkItem(title: "New terminal", kind: .terminal)
        XCTAssertEqual(chat.workState.selectedItem?.terminalWorkingDirectory, ready.projectPath)
        let restarted = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(restarted)
        restarted.selectSession(id)
        try restarted.refreshWorkFiles()
        XCTAssertEqual(restarted.workFileURL(for: migrated), file)
        XCTAssertEqual(restarted.workState.items.first { $0.id == document.id }?.content, migrated.content)
    }

    func testSetupFailureAndCancellationDoNotStartCheckoutAndCanRetry() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.root.appendingPathComponent("Chat"))
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        try await chat.setCurrentWorktreeEnabled(true)
        let id = try XCTUnwrap(chat.currentSessionID)
        let path = try XCTUnwrap(chat.currentWorktree?.path)
        try WorktreeFixture.git(["-C", fixture.repository.path, "remote", "add", "origin", fixture.root.appendingPathComponent("missing.git").path])
        do {
            try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in
                XCTFail("A failed sync must stop before model naming")
                return "fix-login"
            }
            XCTFail("Expected a sync failure")
        } catch { }
        XCTAssertEqual(chat.currentWorktreeSetupProgress?.step, .sync)
        XCTAssertNotNil(chat.currentWorktreeSetupProgress?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try WorktreeFixture.git(["-C", fixture.repository.path, "remote", "remove", "origin"])
        let task = Task {
            try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "fix-login"
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(chat.isPreparingCurrentWorktree)
        XCTAssertEqual(chat.currentWorktreeSetupProgress?.step, .name)
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            do {
                try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in throw error }
                XCTFail("Cancelled naming must not create a random branch")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in "fix-login" }
        XCTAssertTrue(chat.currentWorktree?.isReady == true)
        XCTAssertEqual(chat.currentWorktreeSetupProgress?.isComplete, true)
        XCTAssertNil(chat.currentWorktreeSetupProgress?.error)
    }

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
        let setup = Task { try await first.setCurrentWorktreeEnabled(true) }
        for _ in 0..<100 where !first.isPreparingCurrentWorktree { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(first.isPreparingCurrentWorktree)
        XCTAssertFalse(first.canSend(isRunning: true, selectedModelID: "model"))
        XCTAssertFalse(second.canChangeCurrentWorktree)
        XCTAssertFalse(second.canChangeCurrentProject)
        XCTAssertFalse(second.canModifySession(id))
        first.createSession()
        let newID = first.currentSessionID
        try await setup.value
        XCTAssertEqual(first.currentSessionID, newID)
        XCTAssertNil(first.currentWorktree)
        first.selectSession(id)
        XCTAssertFalse(first.currentWorktree?.isReady == true)
        try await first.prepareWorktree(in: id, firstPrompt: first.draft) { _ in "pending-request" }
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
        try await createReadyWorktree(chat)
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
        try await createReadyWorktree(chat, name: "another-task")
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

    func testSidePaneFilesUseTheProjectSubfolderAndStayIsolatedAcrossChats() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository.appendingPathComponent("Sources"))
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        try await createReadyWorktree(chat)
        let firstID = try XCTUnwrap(chat.currentSessionID)
        let tree = try XCTUnwrap(chat.currentWorktree)
        let directory = URL(fileURLWithPath: tree.projectPath).appendingPathComponent("Nativ Files", isDirectory: true)
        XCTAssertEqual(chat.workFilesDirectory, directory)
        try chat.createWorkItem(title: "Notes", kind: .document, content: "# Original")
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let file = try XCTUnwrap(chat.workFileURL(for: item))
        XCTAssertEqual(file, directory.appendingPathComponent(item.id.uuidString).appendingPathComponent("Notes.md"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Original")
        let read = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: item.id), in: firstID)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        XCTAssertEqual(result["file_path"] as? String, file.path)
        try chat.updateWorkItem(item.id, content: "# Pane", previousContent: "# Original")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Pane")
        try "# Terminal edit".write(to: file, atomically: true, encoding: .utf8)
        try chat.renameWorkItem(item.id, name: "Renamed", previousTitle: item.title)
        let renamed = try XCTUnwrap(chat.workState.selectedItem)
        let renamedFile = try XCTUnwrap(chat.workFileURL(for: renamed))
        XCTAssertEqual(renamedFile.lastPathComponent, "Renamed.md")
        XCTAssertEqual(renamed.content, "# Terminal edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try chat.createWorkItem(title: "Renamed.md", kind: .document, content: "Duplicate")
        let duplicateFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        XCTAssertNotEqual(duplicateFile, renamedFile)
        try chat.createWorkItem(title: "main", kind: .code, content: "print(1)", language: "python")
        let codeFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        XCTAssertEqual(codeFile.pathExtension, "py")
        try chat.createWorkItem(title: "Game", kind: .document, content: "<!DOCTYPE html><html><body>Play</body></html>")
        let htmlFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        XCTAssertEqual(htmlFile.pathExtension, "html")
        XCTAssertTrue(try WorktreeFixture.git(["-C", tree.path, "status", "--porcelain", "--untracked-files=all"]).contains("Game.html"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent("Sources/Nativ Files").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatRoot.appendingPathComponent("Files").path))
        try chat.createWorkItem(title: "Reference", kind: .website, url: "https://example.com")
        let websiteID = try XCTUnwrap(chat.workState.selectedID)
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        let terminalID = try XCTUnwrap(chat.workState.selectedID)
        try chat.refreshWorkFiles()
        XCTAssertTrue(chat.workState.items.contains { $0.id == websiteID })
        XCTAssertTrue(chat.workState.items.contains { $0.id == terminalID })

        chat.createSession(projectID: project.id)
        try await createReadyWorktree(chat, name: "another-task")
        try chat.createWorkItem(title: "Renamed.md", kind: .document, content: "Second checkout")
        let secondFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        XCTAssertFalse(secondFile.path.hasPrefix(tree.path + "/"))
        // A background agent action must resolve the requested chat, not the selected checkout.
        let firstList = try await chat.executeWorkAction(ChatWorkRequest(action: .list), in: firstID)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstList.utf8)) as? [[String: Any]])
        XCTAssertTrue(listed.contains { $0["file_path"] as? String == renamedFile.path })
        chat.selectSession(firstID)
        try chat.deleteWorkItem(item.id) { source in
            XCTAssertEqual(source, renamedFile)
            let trash = fixture.root.appendingPathComponent("trashed.md")
            try FileManager.default.moveItem(at: source, to: trash)
            return trash
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedFile.path))
        XCTAssertEqual(try String(contentsOf: duplicateFile, encoding: .utf8), "Duplicate")
        XCTAssertEqual(try String(contentsOf: secondFile, encoding: .utf8), "Second checkout")
        let restarted = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(restarted)
        restarted.selectSession(firstID)
        try restarted.refreshWorkFiles()
        XCTAssertEqual(restarted.workFilesDirectory, directory)
        XCTAssertFalse(restarted.workState.items.contains { $0.id == item.id })
    }

    func testLegacySidePaneFilesMigrateExternalEditsAndNeverResurrectDeletedFiles() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let store = ChatSessionStore(chatDirectory: chatRoot)
        let id = UUID()
        let tree = try store.worktrees.create(store.worktrees.plan(projectPath: fixture.repository.path, sessionID: id))
        var state = ChatWorkState()
        let item = try state.create(title: "Notes.md", kind: .document, content: "JSON original")
        var session = ChatSession(id: id, title: "Legacy", createdAt: Date(), updatedAt: Date(), messages: [], workState: state)
        XCTAssertTrue(store.saveSession(session))
        let legacy = try XCTUnwrap(store.workFiles.fileURL(for: item, sessionID: id))
        try "Latest external edit".write(to: legacy, atomically: true, encoding: .utf8)
        // Simulate an existing worktree chat saved by the previous version.
        session.worktree = tree
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: chatRoot.appendingPathComponent("Sessions/\(id.uuidString).json"))
        let chat = ChatViewModel(sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.selectSession(id)
        let destination = try XCTUnwrap(store.workFiles(for: tree).fileURL(for: item, sessionID: id))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Existing checkout edits".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try chat.refreshWorkFiles())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Existing checkout edits")
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "Latest external edit")
        XCTAssertNotEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        try FileManager.default.removeItem(at: destination)
        try chat.refreshWorkFiles()
        let migrated = try XCTUnwrap(chat.workState.selectedItem)
        let file = try XCTUnwrap(chat.workFileURL(for: migrated))
        XCTAssertTrue(file.path.hasPrefix(tree.projectPath + "/Nativ Files/"))
        XCTAssertEqual(migrated.content, "Latest external edit")
        XCTAssertEqual(migrated.revision, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Latest external edit")
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "Latest external edit")
        XCTAssertEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        try FileManager.default.removeItem(at: file)
        var staleWindow = try XCTUnwrap(store.loadSession(id: id))
        staleWindow.workFilesInWorktree = nil
        XCTAssertTrue(store.saveSession(staleWindow, previousWorkState: staleWindow.workState))
        XCTAssertEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        chat.closeWorkItem(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try chat.refreshWorkFiles()
        XCTAssertTrue(chat.workState.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testFirstSaveCanMigrateAndRenameALegacyFile() throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let store = ChatSessionStore(chatDirectory: chatRoot)
        let id = UUID()
        let tree = try store.worktrees.create(store.worktrees.plan(projectPath: fixture.repository.path, sessionID: id))
        var state = ChatWorkState()
        let item = try state.create(title: "Original.md", kind: .document, content: "Original")
        var session = ChatSession(id: id, title: "Legacy", createdAt: Date(), updatedAt: Date(), messages: [], workState: state)
        XCTAssertTrue(store.saveSession(session))
        session.worktree = tree
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: chatRoot.appendingPathComponent("Sessions/\(id.uuidString).json"))
        let renamed = try state.update(id: item.id, content: "Edited", expectedRevision: 1, title: "Renamed.md", author: "You")
        session.workState = state
        XCTAssertTrue(store.saveSession(session))
        let file = try XCTUnwrap(store.workFiles(for: tree).fileURL(for: renamed, sessionID: id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Edited")
        XCTAssertEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        let legacy = try XCTUnwrap(store.workFiles.fileURL(for: item, sessionID: id))
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "Original")
    }

    func testSidePaneFileWritesRefuseLinksAndMissingCheckouts() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chatRoot = fixture.root.appendingPathComponent("Chat")
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        try await createReadyWorktree(chat)
        let tree = try XCTUnwrap(chat.currentWorktree)
        let directory = try XCTUnwrap(chat.workFilesDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.repository)
        XCTAssertThrowsError(try chat.createWorkItem(title: "Do not write", kind: .document, content: "Unsafe"))
        XCTAssertTrue(chat.workState.items.isEmpty)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "status", "--porcelain"]), "")
        try FileManager.default.removeItem(at: directory)
        try chat.createWorkItem(title: "Keep.md", kind: .document, content: "Saved")
        let item = try XCTUnwrap(chat.workState.selectedItem)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path))
        XCTAssertNil(chat.workFilesDirectory)
        XCTAssertNil(chat.workFileURL(for: item))
        XCTAssertThrowsError(try chat.refreshWorkFiles())
        XCTAssertThrowsError(try chat.createWorkItem(title: "New.md", kind: .document, content: "New"))
        XCTAssertThrowsError(try chat.updateWorkItem(item.id, content: "Edit", previousContent: "Saved"))
        XCTAssertThrowsError(try chat.deleteWorkItem(item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatRoot.appendingPathComponent("Files").path))
    }

    func testMissingCheckoutCannotFallBackToLocalOrStandaloneRoots() async throws {
        let fixture = try WorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.root.appendingPathComponent("Chat"))
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        try await createReadyWorktree(chat)
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
        do { try await createReadyWorktree(chat); XCTFail("Expected checkout conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already exists")) }
        XCTAssertEqual(chat.currentWorktree?.isReady, false)
        XCTAssertFalse(chat.isPreparingCurrentWorktree)
        XCTAssertTrue(chat.canChangeCurrentWorktree)
        do { try await chat.setCurrentWorktreeEnabled(false); XCTFail("Cannot forget pending worktree files") }
        catch { }
        do { try await chat.setCurrentProject(nil); XCTFail("Cannot detach pending worktree files") }
        catch { }
        XCTAssertEqual(chat.currentProjectID, project.id)
        XCTAssertNotNil(chat.currentWorktree)
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
        try await createReadyWorktree(chat)
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
        try await createReadyWorktree(chat)
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
        for name in ["first-task", "second-task"] {
            chat.createSession(projectID: project.id)
            try await createReadyWorktree(chat, name: name)
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
        try await createReadyWorktree(chat)
        let oldTree = try XCTUnwrap(chat.currentWorktree)
        let html = "<!DOCTYPE html><html><body>Restored game</body></html>"
        try chat.createWorkItem(title: "Game", kind: .document, content: html)
        let game = try XCTUnwrap(chat.workState.selectedItem)
        try chat.createWorkItem(title: "Ignored.tmp", kind: .code, content: "Do not recover")
        let ignored = try XCTUnwrap(chat.workState.selectedItem)
        try "*.tmp\n".write(to: fixture.repository.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        chat.openWorkItem(game.id)
        try "Recovery content".write(to: URL(fileURLWithPath: oldTree.path).appendingPathComponent("draft.txt"),
                                     atomically: true, encoding: .utf8)
        let removed = try await chat.deleteSession(oldID) { _ in true }
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
        let restoredGame = try XCTUnwrap(restarted.workState.selectedItem)
        XCTAssertEqual(restoredGame.id, game.id)
        XCTAssertEqual(restoredGame.content, html)
        XCTAssertEqual(restoredGame.storedFilename, "Game.html")
        let restoredFile = try XCTUnwrap(restarted.workFileURL(for: restoredGame))
        XCTAssertTrue(restoredFile.path.hasPrefix(restored.projectPath + "/Nativ Files/"))
        XCTAssertEqual(try String(contentsOf: restoredFile, encoding: .utf8), html)
        XCTAssertFalse(restarted.workState.items.contains { $0.id == ignored.id })
        try restarted.refreshWorkFiles()
        XCTAssertFalse(restarted.workState.items.contains { $0.id == ignored.id })
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
        try await createReadyWorktree(chat)
        let tree = try XCTUnwrap(chat.currentWorktree)
        try "blocked".write(to: chat.worktreeRecoveryStore.recoveryRoot, atomically: true, encoding: .utf8)
        do { try await chat.deleteSession(id); XCTFail("Cannot delete without a verified snapshot") }
        catch { }
        XCTAssertNotNil(ChatSessionStore(chatDirectory: chatRoot).loadSession(id: id))
        XCTAssertNotNil(tree.availableRootPath)
        XCTAssertTrue(chat.canModifySession(id))
        XCTAssertFalse(chat.isDeletingCurrentSession)
    }

    private func createReadyWorktree(_ chat: ChatViewModel, name: String = "test-task") async throws {
        try await chat.setCurrentWorktreeEnabled(true)
        try await chat.prepareWorktree(in: XCTUnwrap(chat.currentSessionID), firstPrompt: name) { _ in name }
    }

    private func loaded(_ chat: ChatViewModel) async throws {
        for _ in 0..<100 where chat.isLoadingSessions { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(chat.isLoadingSessions)
    }
}
