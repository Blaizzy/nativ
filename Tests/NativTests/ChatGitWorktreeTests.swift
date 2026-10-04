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
            assertEqual((request.status, ChatGitHubPullRequestDetector.decode(output(json), branch: "other"), ChatGitHubPullRequestDetector.decode(output(json), branch: "local", upstreamBranch: "123")),
                        (label, .notFound, .found(request)))
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
            assertEqual((request.command, request.currentDirectoryURL.path, request.environment["GH_PROMPT_DISABLED"], (request.environment["GH_REPO"]) == nil, (request.environment["GIT_DIR"]) == nil),
                        ("exec gh pr view --json number,title,url,state,isDraft,headRefName", "/tmp/project with spaces", "1", true, true))
            XCTAssertEqual(request.timeout, 15)
            return response
        }
        XCTAssertEqual(result, .notFound)
    }
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
private func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

@discardableResult
private func write(_ text: String, to file: URL) throws -> URL {
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file
}

/// XCTest has no tuple overload. Check each field separately and report the caller's line.
private func assertEqual<each Value: Equatable>(_ actual: (repeat each Value), _ expected: (repeat each Value),
                                                file: StaticString = #filePath, line: UInt = #line) {
    for (actual, expected) in repeat (each actual, each expected) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private struct WorktreeFixture {
    let root: URL
    let repository: URL
    let id = UUID()
    var store: ChatGitWorktreeStore { .init(root: root.appendingPathComponent("Worktrees")) }
    var chatRoot: URL { root.appendingPathComponent("Chat") }
    var sessions: ChatSessionStore { .init(chatDirectory: chatRoot) }

    @discardableResult
    func addRemote() throws -> URL {
        let remote = root.appendingPathComponent("remote.git")
        try Self.git(["clone", "--bare", repository.path, remote.path])
        try Self.git(["-C", repository.path, "remote", "add", "origin", remote.path])
        return remote
    }

    init(commit: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        repository = root.appendingPathComponent("Project with spaces")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Self.git(["init", "-b", "main", repository.path])
        try "committed".write(to: repository.appendingPathComponent("Sources/value.txt"), atomically: true, encoding: .utf8)
        if commit {
            try Self.git(["-C", repository.path, "add", "."])
            try Self.git(["-C", repository.path, "commit", "-m", "Initial"])
        }
    }

    @discardableResult
    static func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Test",
                             "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments
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

private extension XCTestCase {
    func makeFixture(commit: Bool = true) throws -> WorktreeFixture {
        let fixture = try WorktreeFixture(commit: commit)
        addTeardownBlock { try FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }
    func makeCheckout() throws -> (WorktreeFixture, UUID, ChatGitWorktree) {
        let fixture = try makeFixture()
        return (fixture, fixture.id, try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: fixture.id)))
    }

}

final class ChatGitWorktreeTests: XCTestCase {
    @MainActor
    func testGitChangeObserverSeesNestedEditsAndWorktreeBranchChangesAndStops() async throws {
        let fixture = try makeFixture()
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
        let fixture = try makeFixture()
        let commit = ["commit", "-m", "Changes"]
        try "old\nrows\n".write(to: fixture.repository.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: fixture.repository.appendingPathComponent("rename.txt"), atomically: true, encoding: .utf8)
        try "ignored.txt\n".write(to: fixture.repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", fixture.repository.path, "add", "."])
        try WorktreeFixture.git(["-C", fixture.repository.path] + commit)
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.appendingPathComponent("Sources").path, sessionID: UUID()))
        let root = URL(fileURLWithPath: tree.path)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.projectPath, fallbackBaseCommit: tree.baseCommit), ChatGitDiffStat())
        let value = try write("first\nsecond\n", to: root.appendingPathComponent("Sources/value.txt"))
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
        XCTAssertEqual(try fixture.store.diffStat(at: tree.projectPath, fallbackBaseCommit: tree.baseCommit), expected)
        XCTAssertEqual(try WorktreeFixture.git(["-C", tree.path, "ls-files", "--stage"]), index)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try WorktreeFixture.git(["-C", tree.path] + commit)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.path, fallbackBaseCommit: tree.baseCommit), expected)
        XCTAssertThrowsError(try fixture.store.diffStat(at: fixture.root.path))
    }

    func testDiffCounterFollowsRemoteBaseThroughMergeAndRestore() async throws {
        let fixture = try makeFixture()
        // No origin/HEAD or local main/master: use the actual remote default branch.
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "-m", "trunk"])
        try fixture.addRemote()
        let id = UUID()
        let synced = try await fixture.store.synchronized(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        let tree = try fixture.store.create(synced.plan)
        XCTAssertEqual(tree.baseReference, "refs/remotes/origin/trunk")
        for (path, name, content) in [(tree.path, "feature.txt", "branch change\n"),
                                      (fixture.repository.path, "upstream.txt", "main line 1\nmain line 2\n")] {
            try content.write(to: URL(fileURLWithPath: path).appendingPathComponent(name), atomically: true, encoding: .utf8)
            try WorktreeFixture.git(["-C", path, "add", "."])
            try WorktreeFixture.git(["-C", path, "commit", "-m", name])
        }
        try WorktreeFixture.git(["-C", fixture.repository.path, "push", "origin", "trunk"])
        try WorktreeFixture.git(["-C", tree.path, "merge", "--no-edit", "origin/trunk"])
        let expected = ChatGitDiffStat(additions: 1, deletions: 0)
        XCTAssertEqual(try fixture.store.diffStat(at: tree.path, baseReference: tree.baseReference,
                                                 fallbackBaseCommit: tree.baseCommit), expected)
        try fixture.store.remove(tree, sessionID: id)
        let record = try XCTUnwrap(fixture.store.snapshots().first)
        let restored = try fixture.store.restore(record.id, to: fixture.store.restorationPlan(record, sessionID: UUID()))
        XCTAssertEqual(restored.baseReference, tree.baseReference)
        XCTAssertEqual(try fixture.store.diffStat(at: restored.path, baseReference: restored.baseReference,
                                                 fallbackBaseCommit: restored.baseCommit), expected)
    }

    func testRandomFallbackPreservesValidNamesAndExcludesOccupiedNames() throws {
        let all = Set(ChatGitWorktreeStore.fallbackBranches)
        let available = "nativ/quiet-cedar"
        let occupied = all.subtracting([available])
        XCTAssertEqual(try ChatGitWorktreeStore.availableBranch("fix-login", excluding: occupied), "nativ/fix-login")
        let invalid = ["", "../../main", "fix; rm -rf /", "Here is the branch: fix-login", "fix\nlogin", "fix--login", String(repeating: "x", count: 61)]
        for response in invalid {
            XCTAssertThrowsError(try ChatGitWorktreeStore.namedBranch(response), response)
        }
        for response in [nil, "quiet-cloud"] + invalid.map(Optional.some) {
            XCTAssertEqual(try ChatGitWorktreeStore.availableBranch(response, excluding: occupied), available, String(describing: response))
        }
        XCTAssertThrowsError(try ChatGitWorktreeStore.availableBranch(nil, excluding: all))
    }

    func testNamedBranchHasNoSessionSuffixAndPreservesExistingBranches() throws {
        let fixture = try makeFixture()
        let id = UUID()
        var plan = try fixture.store.plan(projectPath: fixture.repository.path, sessionID: id)
        plan.branch = try ChatGitWorktreeStore.namedBranch("`Fix-Login-Flow`")
        XCTAssertEqual(plan.branch, "nativ/fix-login-flow")
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", plan.branch])
        XCTAssertFalse(fixture.store.hasStartedCreating(plan))
        XCTAssertThrowsError(try fixture.store.create(plan))
        try assertEqual((fixture.store.removal(plan, sessionID: id).removesManagedBranch, exists(plan.path)), (false, false))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", plan.branch]), plan.baseCommit)
    }

    func testSyncUsesFreshRemoteDefaultBranchWithoutChangingLocalCheckout() async throws {
        let fixture = try makeFixture()
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "-m", "trunk"])
        let remote = try fixture.addRemote()
        let writer = fixture.root.appendingPathComponent("writer")
        try WorktreeFixture.git(["clone", remote.path, writer.path])
        try "remote update".write(to: writer.appendingPathComponent("Sources/value.txt"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", writer.path, "add", "."])
        try WorktreeFixture.git(["-C", writer.path, "commit", "-m", "Remote update"])
        try WorktreeFixture.git(["-C", writer.path, "push", "origin", "trunk"])
        try WorktreeFixture.git(["-C", fixture.repository.path, "switch", "-c", "local-feature"])
        let localHead = try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "HEAD"])
        let localFile = try write("local edits", to: fixture.repository.appendingPathComponent("Sources/value.txt"))
        let id = UUID()
        var synced = try await fixture.store.synchronized(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
        assertEqual((synced.source, synced.plan.baseCommit), ("origin/trunk", try WorktreeFixture.git(["-C", writer.path, "rev-parse", "HEAD"])))
        synced.plan.branch = try ChatGitWorktreeStore.namedBranch("fix-login-flow")
        let ready = try fixture.store.create(synced.plan)
        XCTAssertEqual(try text(URL(fileURLWithPath: ready.path).appendingPathComponent("Sources/value.txt")), "remote update")
        try assertEqual((text(localFile), WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "HEAD"])), ("local edits", localHead))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "local-feature")
        try fixture.store.remove(ready, sessionID: id)
        XCTAssertFalse(exists(ready.path))
    }

    func testIndependentCheckoutsUseCommittedFilesAndPreserveLocalEdits() throws {
        let fixture = try makeFixture()
        let original = try write("local edit", to: fixture.repository.appendingPathComponent("Sources/value.txt"))
        let first = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        let second = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertNotEqual(first.branch, second.branch)
        try assertEqual((first.commonDirectory, first.availableRootPath, WorktreeFixture.git(["-C", first.path, "branch", "--show-current"])),
                    (second.commonDirectory, first.path, first.branch))
        let firstFile = URL(fileURLWithPath: first.path).appendingPathComponent("Sources/value.txt")
        let secondFile = URL(fileURLWithPath: second.path).appendingPathComponent("Sources/value.txt")
        XCTAssertEqual(try text(firstFile), "committed")
        try "first edit".write(to: firstFile, atomically: true, encoding: .utf8)
        try assertEqual((text(secondFile), text(original), WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"])), ("committed", "local edit", "main"))
    }

    func testFileAccessInsideManagedAppStorageCheckoutPreservesPrivateDataProtection() throws {
        let fixture = try makeFixture()
        let appData = fixture.root.appendingPathComponent("Library/Application Support/Nativ")
        let store = ChatGitWorktreeStore(root: appData.appendingPathComponent("Chat/Worktrees"))
        let tree = try store.create(store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        let reads = try FileReadAccessPolicy(rootPath: tree.projectPath)
        let writes = try FileWriteAccessPolicy(rootPath: tree.projectPath)
        let source = try reads.resolve(path: "Sources/value.txt").url
        XCTAssertEqual(try text(source), "committed")
        try write("checkout edit", to: try writes.resolve(path: "Sources/value.txt").url)
        XCTAssertEqual(try text(source), "checkout edit")
        XCTAssertEqual(try text(fixture.repository.appendingPathComponent("Sources/value.txt")), "committed")
        let nested = try FileReadAccessPolicy(rootPath: URL(fileURLWithPath: tree.path).appendingPathComponent("Sources").path)
        XCTAssertEqual(try nested.resolve(path: "value.txt").url, source)
        XCTAssertThrowsError(try reads.resolve(path: ".git"))
        XCTAssertThrowsError(try reads.resolve(path: ".env"))
        XCTAssertThrowsError(try writes.resolve(path: "id_rsa"))
        XCTAssertThrowsError(try reads.resolve(path: "../another-chat/file.txt"))
        XCTAssertThrowsError(try writes.resolve(path: "../another-chat/file.txt"))
        let privateFile = try write("private", to: appData.appendingPathComponent("settings.json"))
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
        let fixture = try makeFixture()
        try WorktreeFixture.git(["-C", fixture.repository.path, "checkout", "--detach"])
        let plan = try fixture.store.plan(projectPath: fixture.repository.appendingPathComponent("Sources").path, sessionID: UUID())
        assertEqual((plan.projectSubpath, (plan.availableRootPath) == nil), ("Sources", true))
        let ready = try fixture.store.create(plan)
        XCTAssertEqual(ready.availableRootPath, URL(fileURLWithPath: ready.path).appendingPathComponent("Sources").path)
        let source = try write("Keep edits", to: URL(fileURLWithPath: ready.projectPath).appendingPathComponent("value.txt"))
        try assertEqual((fixture.store.create(plan), text(source)), (ready, "Keep edits"))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: ready.path).appendingPathComponent(".git"))
        XCTAssertNil(ready.availableRootPath)
        XCTAssertThrowsError(try fixture.store.create(plan))
        XCTAssertEqual(try text(source), "Keep edits")
    }

    func testNonRepositoryAndUnbornRepositoryFailWithoutCreatingCheckout() throws {
        let fixture = try makeFixture(commit: false)
        XCTAssertThrowsError(try fixture.store.plan(projectPath: fixture.root.path, sessionID: UUID()))
        XCTAssertThrowsError(try fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        XCTAssertFalse(exists(fixture.store.root.path))
    }

    func testSetupCanResumeAfterOnlyTheBranchWasCreated() throws {
        let fixture = try makeFixture()
        let plan = try fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID())
        try WorktreeFixture.git(["-C", fixture.repository.path, "branch", plan.branch, plan.baseCommit])
        let ready = try fixture.store.create(plan)
        assertEqual((ready.branch, (ready.availableRootPath) != nil), (plan.branch, true))
    }

    func testRemovalSavesDirtyAndUnmergedWorkAndRequiresConsentForIgnoredFiles() throws {
        let fixture = try makeFixture()
        for kind in ["tracked", "untracked", "ignored", "unmerged"] {
            let id = UUID()
            let worktree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: id))
            let directory = URL(fileURLWithPath: worktree.path)
            let file = try write("Keep my work", to: directory.appendingPathComponent(kind == "tracked" ? "Sources/value.txt" : "generated.txt"))
            if kind == "ignored" {
                try write("generated.txt\n", to: fixture.repository.appendingPathComponent(".git/info/exclude"))
            }
            if kind == "unmerged" {
                try WorktreeFixture.git(["-C", worktree.path, "add", "-f", "."])
                try WorktreeFixture.git(["-C", worktree.path, "commit", "-m", "Worktree work"])
            }
            let assessment = try fixture.store.removal(worktree, sessionID: id)
            XCTAssertEqual(assessment.requiresConfirmation, kind == "ignored", kind)
            XCTAssertEqual(assessment.hasUnmergedCommits, kind == "unmerged", kind)
            XCTAssertEqual(assessment.hasUncommittedFiles, kind != "unmerged", kind)
            if kind == "ignored" { XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: id)) }
            XCTAssertEqual(try text(file), "Keep my work")
            try fixture.store.remove(worktree, sessionID: id, discardChanges: true)
            XCTAssertFalse(exists(worktree.path))
            XCTAssertThrowsError(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "--verify", "refs/heads/\(worktree.branch)"]))
            XCTAssertTrue(try fixture.store.snapshots().contains { $0.sessionID == id })
        }
        XCTAssertEqual(try text(fixture.repository.appendingPathComponent("Sources/value.txt")), "committed")
    }

    func testRemovalOfMergedWorkAndPartialSetupIsRetryable() throws {
        let (fixture, id, worktree) = try makeCheckout()
        try WorktreeFixture.git(["-C", worktree.path, "commit", "--allow-empty", "-m", "Completed"])
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
        let (fixture, id, worktree) = try makeCheckout()
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: UUID(), discardChanges: true))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: worktree.path).appendingPathComponent(".git"))
        XCTAssertThrowsError(try fixture.store.remove(worktree, sessionID: id, discardChanges: true))
        XCTAssertTrue(exists(worktree.path))
    }

    func testMissingCheckoutRegistrationCanBeRemoved() throws {
        let (fixture, id, worktree) = try makeCheckout()
        try FileManager.default.removeItem(at: URL(fileURLWithPath: worktree.path))
        try fixture.store.remove(worktree, sessionID: id)
        XCTAssertFalse(try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "list", "--porcelain"]).contains(worktree.path))
    }

    func testBranchInAnotherCheckoutIsNotDeleted() throws {
        let (fixture, id, worktree) = try makeCheckout()
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "remove", worktree.path])
        let other = fixture.root.appendingPathComponent("Moved checkout")
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "add", other.path, worktree.branch])
        try fixture.store.remove(worktree, sessionID: id)
        try assertEqual((exists(other.path), WorktreeFixture.git(["-C", other.path, "branch", "--show-current"])), (true, worktree.branch))
    }

    func testLiveHeadAndCapturedAgentScopeFollowBranchSwitchRenameAndDetach() throws {
        let fixture = try makeFixture()
        let tree = try fixture.store.create(fixture.store.plan(projectPath: fixture.repository.path, sessionID: UUID()))
        // A queued request keeps its scope value across model/tool rounds. Its prompt must still
        // read live HEAD rather than caching the original branch or needing a session reload.
        let scope = ChatToolScope(projectID: UUID(), projectName: "Project", rootPath: tree.path,
                                  projectToolsEnabled: true, worktree: tree)
        assertEqual((tree.currentHead, scope.systemPrompt?.contains("Current branch: \(tree.branch).") == true), (.branch(tree.branch), true))
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature/live"])
        assertEqual((tree.currentHead, scope.systemPrompt?.contains("Current branch: feature/live.") == true, scope.systemPrompt?.contains(tree.branch) == true),
                    (.branch("feature/live"), true, false))
        try WorktreeFixture.git(["-C", tree.path, "branch", "-m", "feature/renamed"])
        let reloaded = try JSONDecoder().decode(ChatGitWorktree.self, from: JSONEncoder().encode(tree))
        try assertEqual((reloaded.currentHead, fixture.store.currentHead(at: tree.path), scope.systemPrompt?.contains("Current branch: feature/renamed.") == true),
                    (.branch("feature/renamed"), reloaded.currentHead, true))
        try WorktreeFixture.git(["-C", tree.path, "switch", "--detach"])
        assertEqual((tree.currentHead, tree.currentHead?.displayName, scope.systemPrompt?.contains("HEAD is detached at \(tree.baseCommit)") == true, scope.systemPrompt?.contains("Current branch:") == true),
                    (.detached(tree.baseCommit), "Detached HEAD · \(tree.baseCommit.prefix(8))", true, false))
        XCTAssertNotNil(tree.availableRootPath)
        try WorktreeFixture.git(["-C", tree.path, "switch", tree.branch])
        XCTAssertTrue(scope.systemPrompt?.contains("Current branch: \(tree.branch).") == true)
        // Local project controls use the same HEAD representation.
        XCTAssertEqual(try fixture.store.currentHead(at: fixture.repository.path), .branch("main"))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path).appendingPathComponent(".git"))
        assertEqual(((tree.currentHead) == nil, scope.systemPrompt?.contains("Git HEAD is unavailable") == true), (true, true))
    }

    func testSwitchedRenamedAndDetachedCheckoutsSnapshotTheirActualHead() throws {
        for kind in ["new", "existing", "renamed", "detached"] {
            let (fixture, id, tree) = try makeCheckout()
            switch kind {
            case "new": try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature"])
            case "existing":
                try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "feature"])
                try WorktreeFixture.git(["-C", tree.path, "switch", "feature"])
            case "renamed": try WorktreeFixture.git(["-C", tree.path, "branch", "-m", "feature"])
            default: try WorktreeFixture.git(["-C", tree.path, "switch", "--detach"])
            }
            try WorktreeFixture.git(["-C", tree.path, "commit", "--allow-empty", "-m", "New HEAD"])
            let head = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
            XCTAssertNotEqual(head, tree.baseCommit)
            let expectedHead: ChatGitHead = kind == "detached" ? .detached(head) : .branch("feature")
            let file = try write("staged edit", to: URL(fileURLWithPath: tree.path).appendingPathComponent("Sources/value.txt"))
            try WorktreeFixture.git(["-C", tree.path, "add", "."])
            let index = try WorktreeFixture.git(["-C", tree.path, "write-tree"])
            try "unstaged edit".write(to: file, atomically: true, encoding: .utf8)
            let state = try fixture.store.removal(tree, sessionID: id)
            XCTAssertEqual(state.checkoutHead, expectedHead, kind)
            XCTAssertEqual(state.headCommit, head, kind)
            try fixture.store.remove(tree, sessionID: id)
            XCTAssertFalse(exists(tree.path), kind)
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
            try assertEqual((WorktreeFixture.git(["-C", restored.path, "rev-parse", "HEAD"]), WorktreeFixture.git(["-C", restored.path, "write-tree"])), (head, index))
            XCTAssertEqual(try text(URL(fileURLWithPath: restored.path).appendingPathComponent("Sources/value.txt")), "unstaged edit")
            XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "main")
        }
    }

    func testSwitchedCheckoutKeepsOriginalBranchWhenItsHistoryIsNotInTheSnapshot() throws {
        let (fixture, id, tree) = try makeCheckout()
        try WorktreeFixture.git(["-C", tree.path, "commit", "--allow-empty", "-m", "Original branch work"])
        let originalHead = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "other", tree.baseCommit])
        XCTAssertFalse(try fixture.store.removal(tree, sessionID: id).removesManagedBranch)
        try fixture.store.remove(tree, sessionID: id)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/\(tree.branch)"]), originalHead)
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/other"]), tree.baseCommit)
        XCTAssertEqual(try fixture.store.snapshots().first?.head, tree.baseCommit)
    }

    func testSwitchedCheckoutDeletionKeepsManagedBranchUsedByAnotherCheckout() throws {
        let (fixture, id, tree) = try makeCheckout()
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature"])
        let other = fixture.root.appendingPathComponent("Other checkout")
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "add", other.path, tree.branch])
        try fixture.store.remove(tree, sessionID: id)
        try assertEqual((exists(tree.path), WorktreeFixture.git(["-C", other.path, "branch", "--show-current"])), (false, tree.branch))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/feature"]), tree.baseCommit)
    }

    func testMissingSwitchedCheckoutStillSavesItsRecordedHead() throws {
        let (fixture, id, tree) = try makeCheckout()
        try WorktreeFixture.git(["-C", tree.path, "switch", "-c", "feature"])
        try WorktreeFixture.git(["-C", tree.path, "commit", "--allow-empty", "-m", "Keep feature"])
        let head = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path))
        try fixture.store.remove(tree, sessionID: id)
        let snapshot = try XCTUnwrap(fixture.store.snapshots().first)
        try assertEqual((snapshot.head, snapshot.checkoutHead, WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "refs/heads/feature"])),
                    (head, .branch("feature"), head))
    }

    func testRecoveryPreservesHistoryIndexWorkingFilesAndSurvivesGitGarbageCollection() throws {
        let (fixture, id, tree) = try makeCheckout()
        let directory = URL(fileURLWithPath: tree.path)
        try "unmerged work".write(to: directory.appendingPathComponent("history.txt"), atomically: true, encoding: .utf8)
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try WorktreeFixture.git(["-C", tree.path, "commit", "-m", "Unmerged work"])
        let head = try WorktreeFixture.git(["-C", tree.path, "rev-parse", "HEAD"])
        let value = try write("staged", to: directory.appendingPathComponent("Sources/value.txt"))
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
        assertEqual((record.indexTree, record.head, record.title), (index, head, "Saved experiment"))
        try WorktreeFixture.git(["-C", fixture.repository.path, "reflog", "expire", "--expire=now", "--all"])
        try WorktreeFixture.git(["-C", fixture.repository.path, "gc", "--prune=now"])
        let store = ChatGitWorktreeStore(root: fixture.store.root)
        let plan = try store.restorationPlan(record, sessionID: UUID())
        let restored = try store.restore(record.id, to: plan)
        try assertEqual((WorktreeFixture.git(["-C", restored.path, "rev-parse", "HEAD"]), WorktreeFixture.git(["-C", restored.path, "write-tree"])), (head, index))
        XCTAssertEqual(try WorktreeFixture.git(["-C", restored.path, "show", ":Sources/value.txt"]), "staged")
        let restoredDirectory = URL(fileURLWithPath: restored.path)
        XCTAssertEqual(try text(restoredDirectory.appendingPathComponent("Sources/value.txt")), "unstaged")
        XCTAssertEqual(try Data(contentsOf: restoredDirectory.appendingPathComponent("new image.bin")), bytes)
        XCTAssertFalse(exists(restoredDirectory.appendingPathComponent("history.txt").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: restoredDirectory.appendingPathComponent("link").path), "Sources/value.txt")
        XCTAssertEqual(try text(fixture.repository.appendingPathComponent("Sources/value.txt")), "committed")
        try store.permanentlyDeleteSnapshot(record.id)
        try assertEqual((store.snapshots().isEmpty, (restored.availableRootPath) != nil, Data(contentsOf: restoredDirectory.appendingPathComponent("new image.bin"))),
                    (true, true, bytes))
    }

    func testSnapshotFailureKeepsCheckoutBranchAndIndexUnchanged() throws {
        let (fixture, id, tree) = try makeCheckout()
        let file = try write("staged", to: URL(fileURLWithPath: tree.path).appendingPathComponent("Sources/value.txt"))
        try WorktreeFixture.git(["-C", tree.path, "add", "."])
        try "unstaged".write(to: file, atomically: true, encoding: .utf8)
        let index = try WorktreeFixture.git(["-C", tree.path, "write-tree"])
        try "blocked".write(to: fixture.store.recoveryRoot, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.store.remove(tree, sessionID: id))
        try assertEqual((WorktreeFixture.git(["-C", tree.path, "write-tree"]), text(file), (tree.availableRootPath) != nil), (index, "unstaged", true))
        XCTAssertEqual(try WorktreeFixture.git(["-C", tree.path, "branch", "--show-current"]), tree.branch)
    }

    func testCorruptBundleAndOccupiedRestoreDestinationArePreserved() throws {
        let (fixture, id, tree) = try makeCheckout()
        try fixture.store.remove(tree, sessionID: id)
        let record = try XCTUnwrap(fixture.store.snapshots().first)
        let plan = try fixture.store.restorationPlan(record, sessionID: UUID())
        try FileManager.default.createDirectory(atPath: plan.path, withIntermediateDirectories: true)
        let occupied = try write("Keep", to: URL(fileURLWithPath: plan.path).appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try fixture.store.restore(record.id, to: plan))
        XCTAssertEqual(try text(occupied), "Keep")
        let otherPlan = try fixture.store.restorationPlan(record, sessionID: UUID())
        try "bad bundle".write(to: fixture.store.snapshotDirectory(record.id).appendingPathComponent("snapshot.bundle"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try fixture.store.restore(record.id, to: otherPlan))
        try assertEqual((exists(otherPlan.path), fixture.store.snapshots().count), (false, 1))
    }

    func testIgnoredFilesAreListedAndExcludedAndNestedRepositoriesBlockCleanup() throws {
        let (fixture, id, tree) = try makeCheckout()
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
        XCTAssertFalse(exists(URL(fileURLWithPath: restored.path).appendingPathComponent(".env").path))
        XCTAssertTrue(exists(URL(fileURLWithPath: restored.path).appendingPathComponent(".gitignore").path))
        let nested = URL(fileURLWithPath: restored.path).appendingPathComponent("nested")
        try WorktreeFixture.git(["clone", fixture.repository.path, nested.path])
        let restoredID = try XCTUnwrap(UUID(uuidString: URL(fileURLWithPath: restored.path).lastPathComponent))
        XCTAssertThrowsError(try fixture.store.remove(restored, sessionID: restoredID))
        XCTAssertTrue(exists(nested.path))
    }
}

@MainActor
final class ChatWorktreeSessionTests: XCTestCase {
    func testProjectPickerPreservesDraftAndReplansOnlyUncreatedWorktrees() async throws {
        let fixture = try makeFixture()
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let first = try projects.createProject(directoryURL: fixture.repository)
        let other = fixture.root.appendingPathComponent("Other")
        try WorktreeFixture.git(["clone", fixture.repository.path, other.path])
        let second = try projects.createProject(directoryURL: other)
        let nongit = try projects.createProject(directoryURL: fixture.root)
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.chatRoot)
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
        assertEqual((chat.currentProjectID, chat.currentWorktree), (first.id, pending))
        try await chat.setCurrentProject(second.id)
        assertEqual((chat.currentSessionID, chat.currentProjectID, chat.currentWorktree?.repositoryPath, chat.currentWorktree?.isReady, chat.draft),
                    (id, second.id, second.rootPath, false, "Keep this draft"))
        XCTAssertEqual(chat.pendingImageAttachments.map(\.id), [attachment.id])
        let saved = try XCTUnwrap(fixture.sessions.loadSession(id: id))
        assertEqual((saved.projectID, saved.worktree), (second.id, chat.currentWorktree))
        try await chat.setCurrentProject(nil)
        assertEqual(((chat.currentProjectID) == nil, (chat.currentWorktree) == nil, (fixture.sessions.loadSession(id: id)?.projectID) == nil, chat.canChangeCurrentProject, chat.canChangeCurrentWorktree),
                    (true, true, true, true, false))
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
        let (fixture, chat, _, project, _) = try await makeProjectChat()
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
            assertEqual((ready.isReady, (ready.branch.range(of: "^nativ/[a-z]+-[a-z]+$", options: .regularExpression)) != nil, names.insert(ready.branch).inserted),
                        (true, true, true))
            try assertEqual((WorktreeFixture.git(["-C", ready.path, "branch", "--show-current"]), fixture.sessions.loadSession(id: id)?.worktree), (ready.branch, ready))
        }
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "nativ/fix-login"]), original)
    }

    func testFirstPromptPreparationPersistsSelectionAndFinishesInOriginalChat() async throws {
        let (fixture, original, projects, _, id) = try await makeProjectChat()
        try await original.setCurrentWorktreeEnabled(true)
        let pending = try XCTUnwrap(original.currentWorktree)
        assertEqual((pending.isReady, exists(pending.path)), (false, false))
        original.draft = "Keep this draft"
        try await original.setCurrentWorktreeEnabled(false)
        assertEqual(((original.currentWorktree) == nil, (fixture.sessions.loadSession(id: id)?.worktree) == nil, original.draft, exists(pending.path)),
                    (true, true, "Keep this draft", false))
        try await original.setCurrentWorktreeEnabled(true)
        let chat = try await reopenChat(fixture, projects: projects, sessionID: id)
        XCTAssertEqual(chat.currentWorktree, pending)
        try await chat.prepareWorktree(in: id, firstPrompt: "Fix the login button") { prompt in
            assertEqual((prompt, chat.currentWorktreeSetupProgress?.step, chat.currentWorktreeSetupProgress?.source, exists(pending.path), chat.isPreparingCurrentWorktree),
                        ("Fix the login button", .name, "No remote · Using local commit", false, true))
            chat.createSession()
            return "fix-login-button"
        }
        assertEqual(((chat.currentWorktree) == nil, (chat.currentWorktreeSetupProgress) == nil), (true, true))
        chat.selectSession(id)
        let ready = try XCTUnwrap(chat.currentWorktree)
        assertEqual((ready.isReady, ready.branch, chat.currentWorktreeSetupProgress?.isComplete, fixture.sessions.loadSession(id: id)?.worktree),
                    (true, "nativ/fix-login-button", true, ready))
        var settings = NativSettings()
        settings.projectToolsEnabled = true
        XCTAssertEqual(chat.toolScope(for: id, settings: settings).terminalWorkingDirectory, ready.path)
        try await chat.prepareWorktree(in: id, firstPrompt: "Another prompt") { _ in
            XCTFail("Existing worktrees must never sync or be renamed again")
            return "another-name"
        }
        assertEqual((chat.currentWorktree, chat.canChangeCurrentWorktree, chat.canChangeCurrentProject), (ready, false, false))
        do { try await chat.setCurrentWorktreeEnabled(false); XCTFail("Cannot detach an existing checkout") }
        catch { }
        do { try await chat.setCurrentProject(nil); XCTFail("Cannot detach an existing checkout from its project") }
        catch { }
        assertEqual((chat.currentWorktree, (ready.availableRootPath) != nil), (ready, true))
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertNil(chat.currentWorktreeSetupProgress)
    }

    func testDocumentsAndTerminalsWorkBeforeSetupAndDocumentsMigrateWhenReady() async throws {
        let (fixture, chat, projects, project, id) = try await makeProjectChat(subpath: "Sources")
        let store = fixture.sessions
        let document = try document(in: chat, title: "Notes.md", kind: .document, content: "Original")
        let stagedFile = try XCTUnwrap(chat.workFileURL(for: document))
        try await chat.setCurrentWorktreeEnabled(true)
        let pending = try XCTUnwrap(chat.currentWorktree)
        chat.setWorkPaneVisible(true)
        chat.openWorkNewTab()
        try chat.refreshWorkFiles()
        XCTAssertEqual(chat.workFilesDirectory, store.workFiles.directory(for: id))
        try chat.updateWorkItem(document.id, content: "Edited", previousContent: "Original")
        XCTAssertEqual(try text(stagedFile), "Edited")
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        var terminalItem = try XCTUnwrap(chat.workState.selectedItem)
        XCTAssertEqual(terminalItem.terminalWorkingDirectory, project.rootPath)
        terminalItem.terminalWorkingDirectory = pending.projectPath // Tab saved by an older build.
        let terminal = chat.workTerminal(for: terminalItem, sessionID: id)
        terminal.startIfNeeded(arguments: ["-f"])
        defer { terminal.stop() }
        assertEqual((terminal.isRunning, terminal.directory), (true, project.rootPath))
        try await chat.setCurrentWorktreeEnabled(false)
        try await chat.setCurrentWorktreeEnabled(true)
        do {
            try await chat.prepareWorktree(in: id, firstPrompt: "Edit notes") { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        assertEqual((exists(pending.path), chat.workFileURL(for: document)), (false, stagedFile))
        try await chat.prepareWorktree(in: id, firstPrompt: "Edit notes") { _ in
            try "Edited during setup".write(to: stagedFile, atomically: true, encoding: .utf8)
            return "edit-notes"
        }
        let ready = try XCTUnwrap(chat.currentWorktree)
        let migrated = try XCTUnwrap(chat.workState.items.first { $0.id == document.id })
        let file = try XCTUnwrap(chat.workFileURL(for: migrated))
        try assertEqual((file.path.hasPrefix(ready.projectPath + "/Nativ Files/"), migrated.content, text(file), store.loadSession(id: id)?.workFilesInWorktree),
                    (true, "Edited during setup", migrated.content, true))
        assertEqual((chat.workTerminal(for: terminalItem, sessionID: id) === terminal, terminal.isRunning, terminal.directory), (true, true, project.rootPath))
        XCTAssertFalse(exists(URL(fileURLWithPath: project.rootPath).appendingPathComponent("Nativ Files").path))
        try chat.createWorkItem(title: "New terminal", kind: .terminal)
        XCTAssertEqual(chat.workState.selectedItem?.terminalWorkingDirectory, ready.projectPath)
        let restarted = try await reopenChat(fixture, projects: projects, sessionID: id)
        try restarted.refreshWorkFiles()
        assertEqual((restarted.workFileURL(for: migrated), restarted.workState.items.first { $0.id == document.id }?.content), (file, migrated.content))
    }

    func testSetupFailureAndCancellationDoNotStartCheckoutAndCanRetry() async throws {
        let (fixture, chat, _, _, id) = try await makeProjectChat()
        try await chat.setCurrentWorktreeEnabled(true)
        let path = try XCTUnwrap(chat.currentWorktree?.path)
        try WorktreeFixture.git(["-C", fixture.repository.path, "remote", "add", "origin", fixture.root.appendingPathComponent("missing.git").path])
        do {
            try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in
                XCTFail("A failed sync must stop before model naming")
                return "fix-login"
            }
            XCTFail("Expected a sync failure")
        } catch { }
        assertEqual((chat.currentWorktreeSetupProgress?.step, (chat.currentWorktreeSetupProgress?.error) != nil, exists(path)), (.sync, true, false))
        try WorktreeFixture.git(["-C", fixture.repository.path, "remote", "remove", "origin"])
        let task = Task {
            try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "fix-login"
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        assertEqual((exists(path), chat.isPreparingCurrentWorktree, chat.currentWorktreeSetupProgress?.step), (false, false, .name))
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            do {
                try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in throw error }
                XCTFail("Cancelled naming must not create a random branch")
            } catch { }
            XCTAssertFalse(exists(path))
        }
        try await chat.prepareWorktree(in: id, firstPrompt: "Fix login") { _ in "fix-login" }
        assertEqual((chat.currentWorktree?.isReady == true, chat.currentWorktreeSetupProgress?.isComplete, (chat.currentWorktreeSetupProgress?.error) == nil), (true, true, true))
    }

    func testCancellingRemoteSyncStopsTransportAndAllowsRetry() async throws {
        // Stall ls-remote, then fetch. The second transport ignores TERM to exercise escalation.
        for pauseOn in 1...2 {
            let fixture = try makeFixture()
            try fixture.addRemote()
            let upload = fixture.root.appendingPathComponent("slow-upload.sh")
            try """
                #!/bin/sh
                if [ -e "$0.called" ]; then call=2; else call=1; touch "$0.called"; fi
                if [ "$call" = "\(pauseOn)" ]; then
                    \(pauseOn == 2 ? "trap '' TERM" : "")
                    touch "$0.started"
                    exec /bin/sleep 10
                fi
                exec /usr/bin/git-upload-pack "$@"
                """.write(to: upload, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: upload.path)
            try WorktreeFixture.git(["-C", fixture.repository.path, "config", "remote.origin.uploadpack", upload.path])
            let (_, chat, _, _, _) = try await makeProjectChat(fixture)
            chat.draft = "Fix login"
            try await chat.setCurrentWorktreeEnabled(true)
            let id = try XCTUnwrap(chat.currentSessionID)
            let plan = try XCTUnwrap(chat.currentWorktree)
            let task = Task {
                try await chat.prepareWorktree(in: id, firstPrompt: chat.draft) { _ in
                    XCTFail("Cancelled sync must not reach naming")
                    return "fix-login"
                }
            }
            defer { task.cancel() }
            let marker = upload.path + ".started"
            for _ in 0..<250 where !exists(marker) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(exists(marker))
            let cancelledAt = Date()
            task.cancel()
            do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
            assertEqual((chat.isPreparingCurrentWorktree, chat.canSend(isRunning: true, selectedModelID: "model"), chat.currentWorktree, exists(plan.path)),
                        (false, true, plan, false))
            try WorktreeFixture.git(["-C", fixture.repository.path, "config", "--unset", "remote.origin.uploadpack"])
            try await chat.prepareWorktree(in: id, firstPrompt: chat.draft) { _ in "fix-login" }
            XCTAssertTrue(chat.currentWorktree?.isReady == true)
        }
    }

    func testSetupLocksOtherWindowsAndFinishesInTheOriginalChatAfterNavigation() async throws {
        let fixture = try makeFixture()
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let activity = InferenceActivityCoordinator()
        let changes = PersistedDataChangeHub()
        let first = ChatViewModel(persistedDataChanges: changes, inferenceActivity: activity,
                                  projectStore: projects, sessionDirectory: fixture.chatRoot)
        try await loaded(first)
        first.createSession(projectID: project.id)
        let id = try XCTUnwrap(first.currentSessionID)
        let second = ChatViewModel(persistedDataChanges: changes, inferenceActivity: activity,
                                   projectStore: projects, sessionDirectory: fixture.chatRoot)
        try await loaded(second)
        second.selectSession(id)
        first.draft = "A pending request"
        let setup = Task { try await first.setCurrentWorktreeEnabled(true) }
        for _ in 0..<100 where !first.isPreparingCurrentWorktree { try await Task.sleep(for: .milliseconds(1)) }
        assertEqual((first.isPreparingCurrentWorktree, first.canSend(isRunning: true, selectedModelID: "model"), second.canChangeCurrentWorktree, second.canChangeCurrentProject, second.canModifySession(id)),
                    (true, false, false, false, false))
        first.createSession()
        let newID = first.currentSessionID
        try await setup.value
        assertEqual((first.currentSessionID, (first.currentWorktree) == nil), (newID, true))
        first.selectSession(id)
        XCTAssertFalse(first.currentWorktree?.isReady == true)
        try await first.prepareWorktree(in: id, firstPrompt: first.draft) { _ in "pending-request" }
        assertEqual((first.currentWorktree?.isReady == true, second.canModifySession(id), fixture.sessions.loadSession(id: id)?.worktree), (true, true, first.currentWorktree))
    }

    func testRoutingPersistsAndEmptyWorktreeChatsAreNotReusedOrPruned() async throws {
        let (fixture, chat, projects, project, firstID) = try await makeProjectChat()
        let first = try await createReadyWorktree(chat)
        var settings = NativSettings()
        settings.projectToolsEnabled = true
        let scope = chat.toolScope(for: firstID, settings: settings)
        assertEqual((scope.fileReadRootPath, scope.fileWriteRootPath, scope.terminalWorkingDirectory, scope.projectToolsAreAvailable, scope.systemPrompt?.contains(first.branch) == true),
                    (first.path, first.path, first.path, true, true))
        chat.createSession(projectID: project.id)
        XCTAssertNotEqual(chat.currentSessionID, firstID)
        try assertEqual(((chat.currentWorktree) == nil, chat.toolScope(for: XCTUnwrap(chat.currentSessionID), settings: settings).rootPath), (true, project.rootPath))
        try await createReadyWorktree(chat, name: "another-task")
        XCTAssertNotEqual(chat.currentWorktree?.path, first.path)
        XCTAssertEqual(chat.toolScope(for: firstID, settings: settings), scope)
        let restored = try await reopenChat(fixture, projects: projects, sessionID: firstID)
        assertEqual((restored.currentWorktree, restored.toolScope(for: firstID, settings: settings), restored.sessions.contains { $0.id == firstID && $0.worktree == first }),
                    (first, scope, true))
        try restored.createWorkItem(title: "Terminal", kind: .terminal)
        let terminal = restored.workTerminal(for: try XCTUnwrap(restored.workState.selectedItem), sessionID: firstID)
        XCTAssertEqual(terminal.directory, first.path)
        // Deleting a clean chat removes only its dedicated checkout and branch.
        try await restored.deleteSession(firstID)
        XCTAssertFalse(exists(first.path))
        XCTAssertThrowsError(try WorktreeFixture.git(["-C", fixture.repository.path, "rev-parse", "--verify", "refs/heads/\(first.branch)"]))
    }

    func testSidePaneFilesUseTheProjectSubfolderAndStayIsolatedAcrossChats() async throws {
        let (fixture, chat, projects, project, firstID) = try await makeProjectChat(subpath: "Sources")
        try await createReadyWorktree(chat)
        let tree = try XCTUnwrap(chat.currentWorktree)
        let directory = URL(fileURLWithPath: tree.projectPath).appendingPathComponent("Nativ Files", isDirectory: true)
        XCTAssertEqual(chat.workFilesDirectory, directory)
        let item = try document(in: chat, title: "Notes", kind: .document, content: "# Original")
        let file = try XCTUnwrap(chat.workFileURL(for: item))
        try assertEqual((file, text(file)), (directory.appendingPathComponent(item.id.uuidString).appendingPathComponent("Notes.md"), "# Original"))
        let read = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: item.id), in: firstID)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        XCTAssertEqual(result["file_path"] as? String, file.path)
        try chat.updateWorkItem(item.id, content: "# Pane", previousContent: "# Original")
        XCTAssertEqual(try text(file), "# Pane")
        try "# Terminal edit".write(to: file, atomically: true, encoding: .utf8)
        try chat.renameWorkItem(item.id, name: "Renamed", previousTitle: item.title)
        let renamed = try XCTUnwrap(chat.workState.selectedItem)
        let renamedFile = try XCTUnwrap(chat.workFileURL(for: renamed))
        assertEqual((renamedFile.lastPathComponent, renamed.content, exists(file.path)), ("Renamed.md", "# Terminal edit", false))
        try chat.createWorkItem(title: "Renamed.md", kind: .document, content: "Duplicate")
        let duplicateFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        XCTAssertNotEqual(duplicateFile, renamedFile)
        try chat.createWorkItem(title: "main", kind: .code, content: "print(1)", language: "python")
        let codeFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        XCTAssertEqual(codeFile.pathExtension, "py")
        try chat.createWorkItem(title: "Game", kind: .document, content: "<!DOCTYPE html><html><body>Play</body></html>")
        let htmlFile = try XCTUnwrap(chat.workFileURL(for: XCTUnwrap(chat.workState.selectedItem)))
        try assertEqual((htmlFile.pathExtension, WorktreeFixture.git(["-C", tree.path, "status", "--porcelain", "--untracked-files=all"]).contains("Game.html")), ("html", true))
        XCTAssertFalse(exists(fixture.repository.appendingPathComponent("Sources/Nativ Files").path))
        XCTAssertFalse(exists(fixture.chatRoot.appendingPathComponent("Files").path))
        try chat.createWorkItem(title: "Reference", kind: .website, url: "https://example.com")
        let websiteID = try XCTUnwrap(chat.workState.selectedID)
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        let terminalID = try XCTUnwrap(chat.workState.selectedID)
        try chat.refreshWorkFiles()
        assertEqual((chat.workState.items.contains { $0.id == websiteID }, chat.workState.items.contains { $0.id == terminalID }), (true, true))

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
        try assertEqual((exists(renamedFile.path), text(duplicateFile), text(secondFile)), (false, "Duplicate", "Second checkout"))
        let restarted = try await reopenChat(fixture, projects: projects, sessionID: firstID)
        try restarted.refreshWorkFiles()
        assertEqual((restarted.workFilesDirectory, restarted.workState.items.contains { $0.id == item.id }), (directory, false))
    }

    func testLegacySidePaneFilesMigrateExternalEditsAndNeverResurrectDeletedFiles() async throws {
        let fixture = try makeFixture()
        let store = fixture.sessions
        let id = UUID()
        let tree = try store.worktrees.create(store.worktrees.plan(projectPath: fixture.repository.path, sessionID: id))
        var state = ChatWorkState()
        let item = try state.create(title: "Notes.md", kind: .document, content: "JSON original")
        var session = ChatSession(id: id, title: "Legacy", createdAt: Date(), updatedAt: Date(), messages: [], workState: state)
        XCTAssertTrue(store.saveSession(session))
        let legacy = try write("Latest external edit", to: try XCTUnwrap(store.workFiles.fileURL(for: item, sessionID: id)))
        // Simulate an existing worktree chat saved by the previous version.
        session.worktree = tree
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: fixture.chatRoot.appendingPathComponent("Sessions/\(id.uuidString).json"))
        let chat = ChatViewModel(sessionDirectory: fixture.chatRoot)
        try await loaded(chat)
        chat.selectSession(id)
        let destination = try XCTUnwrap(store.workFiles(for: tree).fileURL(for: item, sessionID: id))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Existing checkout edits".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try chat.refreshWorkFiles())
        try assertEqual((text(destination), text(legacy)), ("Existing checkout edits", "Latest external edit"))
        XCTAssertNotEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        try FileManager.default.removeItem(at: destination)
        try chat.refreshWorkFiles()
        let migrated = try XCTUnwrap(chat.workState.selectedItem)
        let file = try XCTUnwrap(chat.workFileURL(for: migrated))
        try assertEqual((file.path.hasPrefix(tree.projectPath + "/Nativ Files/"), migrated.content, migrated.revision, text(file), text(legacy)),
                    (true, "Latest external edit", 2, "Latest external edit", "Latest external edit"))
        XCTAssertEqual(store.loadSession(id: id)?.workFilesInWorktree, true)
        try FileManager.default.removeItem(at: file)
        var staleWindow = try XCTUnwrap(store.loadSession(id: id))
        staleWindow.workFilesInWorktree = nil
        assertEqual((store.saveSession(staleWindow, previousWorkState: staleWindow.workState), store.loadSession(id: id)?.workFilesInWorktree, exists(file.path)),
                    (true, true, false))
        chat.closeWorkItem(item.id)
        XCTAssertFalse(exists(file.path))
        try chat.refreshWorkFiles()
        assertEqual((chat.workState.items.isEmpty, exists(file.path), exists(legacy.path)), (true, false, true))
    }

    func testFirstSaveCanMigrateAndRenameALegacyFile() throws {
        let fixture = try makeFixture()
        let store = fixture.sessions
        let id = UUID()
        let tree = try store.worktrees.create(store.worktrees.plan(projectPath: fixture.repository.path, sessionID: id))
        var state = ChatWorkState()
        let item = try state.create(title: "Original.md", kind: .document, content: "Original")
        var session = ChatSession(id: id, title: "Legacy", createdAt: Date(), updatedAt: Date(), messages: [], workState: state)
        XCTAssertTrue(store.saveSession(session))
        session.worktree = tree
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: fixture.chatRoot.appendingPathComponent("Sessions/\(id.uuidString).json"))
        let renamed = try state.update(id: item.id, content: "Edited", expectedRevision: 1, title: "Renamed.md", author: "You")
        session.workState = state
        XCTAssertTrue(store.saveSession(session))
        let file = try XCTUnwrap(store.workFiles(for: tree).fileURL(for: renamed, sessionID: id))
        try assertEqual((text(file), store.loadSession(id: id)?.workFilesInWorktree), ("Edited", true))
        let legacy = try XCTUnwrap(store.workFiles.fileURL(for: item, sessionID: id))
        XCTAssertEqual(try text(legacy), "Original")
    }

    func testSidePaneFileWritesRefuseLinksAndMissingCheckouts() async throws {
        let (fixture, chat, _, _, _) = try await makeProjectChat()
        let tree = try await createReadyWorktree(chat)
        let directory = try XCTUnwrap(chat.workFilesDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.repository)
        XCTAssertThrowsError(try chat.createWorkItem(title: "Do not write", kind: .document, content: "Unsafe"))
        try assertEqual((chat.workState.items.isEmpty, WorktreeFixture.git(["-C", fixture.repository.path, "status", "--porcelain"])), (true, ""))
        try FileManager.default.removeItem(at: directory)
        let item = try document(in: chat, title: "Keep.md", kind: .document, content: "Saved")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tree.path))
        assertEqual(((chat.workFilesDirectory) == nil, (chat.workFileURL(for: item)) == nil), (true, true))
        XCTAssertThrowsError(try chat.refreshWorkFiles())
        XCTAssertThrowsError(try chat.createWorkItem(title: "New.md", kind: .document, content: "New"))
        XCTAssertThrowsError(try chat.updateWorkItem(item.id, content: "Edit", previousContent: "Saved"))
        XCTAssertThrowsError(try chat.deleteWorkItem(item.id))
        XCTAssertFalse(exists(tree.path))
        XCTAssertFalse(exists(fixture.chatRoot.appendingPathComponent("Files").path))
    }

    func testMissingCheckoutCannotFallBackToLocalOrStandaloneRoots() async throws {
        let (fixture, chat, _, project, _) = try await makeProjectChat()
        let reference = try await createReadyWorktree(chat)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: reference.path))
        var settings = NativSettings()
        settings.projectToolsEnabled = true
        settings.fileReadRootPath = fixture.repository.path
        settings.fileWriteRootPath = fixture.repository.path
        let scope = chat.toolScope(for: try XCTUnwrap(chat.currentSessionID), settings: settings)
        assertEqual((scope.isProject, (scope.fileReadRootPath) == nil, (scope.fileWriteRootPath) == nil, scope.projectToolsAreAvailable, scope.terminalWorkingDirectory),
                    (true, true, true, false, reference.path))
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        let terminal = chat.workTerminal(for: try XCTUnwrap(chat.workState.selectedItem), sessionID: try XCTUnwrap(chat.currentSessionID))
        terminal.startIfNeeded(shell: "/bin/zsh", arguments: ["-f"])
        assertEqual((terminal.isRunning, terminal.status), (false, "Folder unavailable"))
        // Detaching from a removed project also retains the checkout association.
        let kept = try await chat.removeProjectSessions(projectID: project.id, disposition: .keepChats)
        XCTAssertTrue(kept)
        let detached = chat.toolScope(for: try XCTUnwrap(chat.currentSessionID), settings: settings)
        assertEqual((detached.isProject, (detached.rootPath) == nil), (true, true))
    }

    func testFailedSetupPreservesReservationAndDoesNotOverwriteExistingFiles() async throws {
        let (fixture, chat, _, project, id) = try await makeProjectChat()
        let path = fixture.chatRoot.appendingPathComponent("Worktrees/\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let existing = try write("Keep me", to: path.appendingPathComponent("keep.txt"))
        do { try await createReadyWorktree(chat); XCTFail("Expected checkout conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already exists")) }
        assertEqual((chat.currentWorktree?.isReady, chat.isPreparingCurrentWorktree, chat.canChangeCurrentWorktree), (false, false, true))
        do { try await chat.setCurrentWorktreeEnabled(false); XCTFail("Cannot forget pending worktree files") }
        catch { }
        do { try await chat.setCurrentProject(nil); XCTFail("Cannot detach pending worktree files") }
        catch { }
        try assertEqual((chat.currentProjectID, (chat.currentWorktree) != nil, text(existing), fixture.sessions.loadSession(id: id)?.worktree),
                    (project.id, true, "Keep me", chat.currentWorktree))
    }

    func testDeletionCancelKeepsChatAndConsentRemovesCheckoutAndBranch() async throws {
        let fixture = try makeFixture()
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository)
        let activity = InferenceActivityCoordinator()
        let chat = ChatViewModel(inferenceActivity: activity, projectStore: projects, sessionDirectory: fixture.chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        let id = try XCTUnwrap(chat.currentSessionID)
        let worktree = try await createReadyWorktree(chat)
        let file = try write("Keep me", to: URL(fileURLWithPath: worktree.path).appendingPathComponent("keep.txt"))
        try "keep.txt\n".write(to: fixture.repository.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let canceled = try await chat.deleteSession(id) { warning in
            assertEqual((warning.contains("ignored"), chat.canModifySession(id), chat.isDeletingCurrentSession, chat.canSend(isRunning: true, selectedModelID: "model")),
                        (true, false, true, false))
            return false
        }
        try assertEqual((canceled, (fixture.sessions.loadSession(id: id)) != nil, text(file), chat.canModifySession(id)), (false, true, "Keep me", true))
        let removed = try await chat.deleteSession(id) { _ in true }
        assertEqual((removed, (fixture.sessions.loadSession(id: id)) == nil, exists(worktree.path), activity.hasActiveOperations), (true, true, false, false))
    }

    func testCleanupFailureKeepsChatForRetryAndProjectKeepChatsKeepsCheckout() async throws {
        let (fixture, chat, _, project, id) = try await makeProjectChat()
        let worktree = try await createReadyWorktree(chat)
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "lock", worktree.path])
        do { try await chat.deleteSession(id); XCTFail("Locked checkout must be preserved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("locked")) }
        assertEqual((chat.canModifySession(id), (fixture.sessions.loadSession(id: id)) != nil, exists(worktree.path)), (true, true, true))
        let kept = try await chat.removeProjectSessions(projectID: project.id, disposition: .keepChats)
        assertEqual((kept, chat.currentWorktree, exists(worktree.path)), (true, worktree, true))
        try WorktreeFixture.git(["-C", fixture.repository.path, "worktree", "unlock", worktree.path])
        try await chat.deleteSession(id)
        XCTAssertFalse(exists(worktree.path))
    }

    func testDeletingProjectChatsCleansAllManagedWorktrees() async throws {
        let (fixture, chat, _, project, _) = try await makeProjectChat()

        var checkouts: [ChatGitWorktree] = []
        for name in ["first-task", "second-task"] {
            chat.createSession(projectID: project.id)
            checkouts.append(try await createReadyWorktree(chat, name: name))
        }
        let removed = try await chat.removeProjectSessions(projectID: project.id, disposition: .deleteChats)
        assertEqual((removed, chat.sessions.contains { $0.projectID == project.id }), (true, false))
        for checkout in checkouts { XCTAssertFalse(exists(checkout.path)) }
        XCTAssertTrue(exists(fixture.repository.path))
        XCTAssertEqual(try WorktreeFixture.git(["-C", fixture.repository.path, "branch", "--show-current"]), "main")
    }

    func testDeletedChatCanRestoreWorkInANewChatAfterRestart() async throws {
        let (fixture, chat, projects, project, oldID) = try await makeProjectChat()
        let oldTree = try await createReadyWorktree(chat)
        let html = "<!DOCTYPE html><html><body>Restored game</body></html>"
        let game = try document(in: chat, title: "Game", kind: .document, content: html)
        let ignored = try document(in: chat, title: "Ignored.tmp", kind: .code, content: "Do not recover")
        try "*.tmp\n".write(to: fixture.repository.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        chat.openWorkItem(game.id)
        try "Recovery content".write(to: URL(fileURLWithPath: oldTree.path).appendingPathComponent("draft.txt"),
                                     atomically: true, encoding: .utf8)
        let removed = try await chat.deleteSession(oldID) { _ in true }
        assertEqual((removed, (fixture.sessions.loadSession(id: oldID)) == nil), (true, true))
        let restarted = ChatViewModel(projectStore: projects, sessionDirectory: fixture.chatRoot)
        try await loaded(restarted)
        let record = try XCTUnwrap(restarted.worktreeRecoveryStore.snapshots().first)
        let newID = try await restarted.restoreWorktreeSnapshot(record.id)
        XCTAssertNotEqual(oldID, newID)
        restarted.selectSession(newID)
        let restored = try XCTUnwrap(restarted.currentWorktree)
        XCTAssertNotEqual(restored.path, oldTree.path)
        try assertEqual((restarted.currentProjectID, restarted.messages.isEmpty, text(URL(fileURLWithPath: restored.path).appendingPathComponent("draft.txt"))),
                    (project.id, true, "Recovery content"))
        assertEqual((fixture.sessions.loadSession(id: newID)?.worktree, restarted.toolScope(for: newID, settings: NativSettings()).rootPath), (restored, restored.projectPath))
        let restoredGame = try XCTUnwrap(restarted.workState.selectedItem)
        assertEqual((restoredGame.id, restoredGame.content, restoredGame.storedFilename), (game.id, html, "Game.html"))
        let restoredFile = try XCTUnwrap(restarted.workFileURL(for: restoredGame))
        try assertEqual((restoredFile.path.hasPrefix(restored.projectPath + "/Nativ Files/"), text(restoredFile), restarted.workState.items.contains { $0.id == ignored.id }),
                    (true, html, false))
        try restarted.refreshWorkFiles()
        XCTAssertFalse(restarted.workState.items.contains { $0.id == ignored.id })
        try await restarted.permanentlyDeleteWorktreeSnapshot(record.id)
        try assertEqual((restarted.worktreeRecoveryStore.snapshots().isEmpty, (restored.availableRootPath) != nil), (true, true))
    }

    func testSnapshotPersistenceFailureKeepsChatAndWorktree() async throws {
        let (fixture, chat, _, _, id) = try await makeProjectChat()
        let tree = try await createReadyWorktree(chat)
        try "blocked".write(to: chat.worktreeRecoveryStore.recoveryRoot, atomically: true, encoding: .utf8)
        do { try await chat.deleteSession(id); XCTFail("Cannot delete without a verified snapshot") }
        catch { }
        assertEqual(((fixture.sessions.loadSession(id: id)) != nil, (tree.availableRootPath) != nil, chat.canModifySession(id), chat.isDeletingCurrentSession),
                    (true, true, true, false))
    }

    private func document(in chat: ChatViewModel, title: String, kind: ChatWorkItem.Kind = .document, content: String) throws -> ChatWorkItem {
        try chat.createWorkItem(title: title, kind: kind, content: content)
        return try XCTUnwrap(chat.workState.selectedItem)
    }

    private func reopenChat(_ fixture: WorktreeFixture, projects: ChatProjectStore, sessionID: UUID) async throws -> ChatViewModel {
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.chatRoot)
        try await loaded(chat)
        chat.selectSession(sessionID)
        return chat
    }

    private func makeProjectChat(_ existing: WorktreeFixture? = nil, subpath: String = "") async throws
        -> (WorktreeFixture, ChatViewModel, ChatProjectStore, ChatProject, UUID) {
        let fixture = try existing ?? makeFixture()
        let projects = ChatProjectStore(storageURL: fixture.root.appendingPathComponent("projects.json"))
        let project = try projects.createProject(directoryURL: fixture.repository.appendingPathComponent(subpath))
        let chat = ChatViewModel(projectStore: projects, sessionDirectory: fixture.chatRoot)
        try await loaded(chat)
        chat.createSession(projectID: project.id)
        return (fixture, chat, projects, project, try XCTUnwrap(chat.currentSessionID))
    }

    @discardableResult
    private func createReadyWorktree(_ chat: ChatViewModel, name: String = "test-task") async throws -> ChatGitWorktree {
        try await chat.setCurrentWorktreeEnabled(true)
        try await chat.prepareWorktree(in: XCTUnwrap(chat.currentSessionID), firstPrompt: name) { _ in name }
        return try XCTUnwrap(chat.currentWorktree)
    }

    private func loaded(_ chat: ChatViewModel) async throws {
        for _ in 0..<100 where chat.isLoadingSessions { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(chat.isLoadingSessions)
    }
}
