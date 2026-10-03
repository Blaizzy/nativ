import Foundation

struct ChatGitHubPullRequest: Decodable, Equatable, Sendable {
    enum State: String, Decodable, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }
    let number: Int
    let title: String
    let url: URL
    let state: State
    let isDraft: Bool
    let headRefName: String

    var status: String {
        switch state {
        case .open: isDraft ? "Draft" : "Open"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }

    var statusIconName: String {
        switch state {
        case .open: isDraft ? "GitHubPR-draft" : "GitHubPR-open"
        case .closed: "GitHubPR-closed"
        case .merged: "GitHubPR-merged"
        }
    }
}

enum ChatPullRequestLookup: Equatable, Sendable {
    case found(ChatGitHubPullRequest)
    case notFound
    case unavailable(String)
}

enum ChatGitHubPullRequestDetector {
    // Resolve the Finder-launched app's PATH once, off the main actor. Authentication
    // stays with gh; no tokens are copied into Nativ or interactive login is started.
    private static let environment: [String: String] = {
        var result = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let path = ShellEnvironment.resolveFromLoginShell(names: ["PATH"])["PATH"]
        result["PATH"] = path ?? result["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result["GH_REPO"] = nil
        result["GH_HOST"] = nil
        result["GH_PROMPT_DISABLED"] = "1"
        result["GH_NO_UPDATE_NOTIFIER"] = "1"
        result["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["LC_ALL"] = "C"
        return result
    }()

    static func lookup(at directory: String, branch: String,
                       run: ChatTerminalToolDependencies.Run = { try await TerminalProcessRunner().run($0) }) async throws -> ChatPullRequestLookup {
        let (environment, upstream) = await Task.detached {
            let store = ChatGitWorktreeStore(root: URL(fileURLWithPath: directory))
            let ref = try? store.git(["config", "--get", "branch.\(branch).merge"], at: directory)
            let upstream = ref.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : nil }
            return (Self.environment, upstream)
        }.value
        try Task.checkCancellation()
        // With no branch argument gh handles upstreams and forks itself. In particular,
        // a numeric branch name cannot be mistaken for a pull-request number.
        let result = try await run(TerminalProcessRequest(
            command: "exec gh pr view --json number,title,url,state,isDraft,headRefName",
            currentDirectoryURL: URL(fileURLWithPath: directory), timeout: 15, environment: environment
        ))
        return decode(result, branch: branch, upstreamBranch: upstream)
    }

    static func decode(_ result: TerminalProcessResult, branch: String, upstreamBranch: String? = nil) -> ChatPullRequestLookup {
        if result.timedOut { return .unavailable("GitHub lookup timed out") }
        if result.exitCode == 127 { return .unavailable("Install GitHub CLI to detect pull requests") }
        if result.exitCode == 4 || result.stderr.contains("gh auth login") {
            return .unavailable("Sign in with gh auth login")
        }
        if result.exitCode == 1, result.stderr.hasPrefix("no pull requests found for branch ") {
            return .notFound
        }
        guard result.exitCode == 0, !result.outputTruncated,
              let request = try? JSONDecoder().decode(ChatGitHubPullRequest.self, from: Data(result.stdout.utf8)),
              request.number > 0, request.url.scheme == "https", request.url.host != nil,
              request.url.path.hasSuffix("/pull/\(request.number)") else {
            return .unavailable("Couldn’t check GitHub pull requests")
        }
        // A branch switch during lookup must never attach the previous branch's PR.
        guard request.headRefName == branch || request.headRefName == upstreamBranch else { return .notFound }
        return .found(request)
    }
}
