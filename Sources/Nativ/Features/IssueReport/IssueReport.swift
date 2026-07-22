import AppKit
import Foundation
import NativServerKit

enum IssueReportCategory: String, CaseIterable, Identifiable {
    case modelDownload
    case modelInference
    case appUI
    case appInteraction
    case crash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelDownload: "Model download"
        case .modelInference: "Model inference"
        case .appUI: "App UI"
        case .appInteraction: "App interaction"
        case .crash: "Crash"
        }
    }

    var systemImage: String {
        switch self {
        case .modelDownload: "arrow.down.circle"
        case .modelInference: "cpu"
        case .appUI: "macwindow"
        case .appInteraction: "cursorarrow.click.2"
        case .crash: "exclamationmark.octagon"
        }
    }

    var githubLabel: String {
        "bug"
    }

    var detailPrompt: String {
        switch self {
        case .modelDownload:
            "Which model were you downloading, and what happened? Include the point where it failed or stalled."
        case .modelInference:
            "Which model was loaded, and what did you send? Describe what you expected and what you got instead."
        case .appUI:
            "What looks wrong, and on which page? Describe what you saw and what you expected."
        case .appInteraction:
            "What were you trying to do, and what got in the way? List the steps you took."
        case .crash:
            "What were you doing when the app crashed? Recent crash reports are attached automatically."
        }
    }
}

struct IssueDiagnosticsSection: Equatable {
    let title: String
    let lines: [String]
}

@MainActor
enum IssueDiagnostics {
    static func collect(
        category: IssueReportCategory,
        model: NativModel,
        runtime: SystemRuntimeMonitor
    ) -> [IssueDiagnosticsSection] {
        var sections = [environmentSection(runtime: runtime), modelSection(model: model)]
        switch category {
        case .modelDownload:
            sections.append(downloadSection(model: model))
        case .modelInference:
            if let inference = inferenceSection(model: model) {
                sections.append(inference)
            }
        case .crash:
            if let crashes = crashSection() {
                sections.append(crashes)
            }
        case .appUI, .appInteraction:
            break
        }
        return sections
    }

    static func serverOutputTail(model: NativModel, maxLines: Int = 60) -> [String] {
        let lines = model.logText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(lines.suffix(maxLines))
    }

    private static func environmentSection(runtime: SystemRuntimeMonitor) -> IssueDiagnosticsSection {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let totalMemory = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: runtime.totalMemoryBytes),
            countStyle: .memory
        )
        let usedMemory = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: runtime.usedMemoryBytes),
            countStyle: .memory
        )
        return IssueDiagnosticsSection(title: "Environment", lines: [
            "Nativ: \(version) (\(build))",
            "macOS: \(runtime.macOSVersion) (\(runtime.macOSBuild))",
            "Chip: \(runtime.chipName)",
            "Memory: \(totalMemory) total, \(usedMemory) in use",
            "mlx-vlm: \(runtime.mlxVLMVersion)"
        ])
    }

    private static func modelSection(model: NativModel) -> IssueDiagnosticsSection {
        let settings = model.settings.normalized()
        var lines = [
            "Server: \(model.isRunning ? "running" : "stopped")",
            "Selected model: \(model.selectedModelDisplay)",
            "Loaded model: \(model.loadedModelDisplay)",
            "Max output tokens: \(settings.maxTokens)",
            "Context window: \(settings.maxKVSize > 0 ? String(settings.maxKVSize) : "model default")",
            "KV quantization: \(settings.kvQuantizationEnabled ? "\(Int(settings.kvBits))-bit, group \(settings.kvGroupSize)" : "off")",
            "Speculative decoding: \(settings.speculativeDecodingEnabled && !settings.draftModelID.isEmpty ? settings.draftModelID : "off")",
            "Prefix caching: \(settings.prefixCachingEnabled ? "on" : "off")",
            "Thinking: \(settings.thinkingEnabled ? "on" : "off")"
        ]
        if model.settingsRequireRestart {
            lines.append("Pending settings change: server restart required")
        }
        return IssueDiagnosticsSection(title: "Model & server", lines: lines)
    }

    private static func downloadSection(model: NativModel) -> IssueDiagnosticsSection {
        let cachePath = LocalModelDiscovery.expandedPath(model.settings.modelSearchPath)
        var lines = ["Model cache path: \(cachePath)"]
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: cachePath),
           let freeBytes = attributes[.systemFreeSize] as? Int64 {
            lines.append("Free disk space: \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))")
        }
        return IssueDiagnosticsSection(title: "Downloads", lines: lines)
    }

    private static func inferenceSection(model: NativModel) -> IssueDiagnosticsSection? {
        guard let metrics = model.metrics else {
            if let error = model.lastMetricsError {
                return IssueDiagnosticsSection(title: "Inference", lines: ["Metrics unavailable: \(error)"])
            }
            return nil
        }
        var lines = NativStats.sessionEntries(metrics).map { "\($0.label): \($0.value)" }
        if let latest = metrics.latest {
            lines.append("— Latest request —")
            lines.append(contentsOf: NativStats.latestRequestEntries(latest).map { "\($0.label): \($0.value)" })
        }
        return IssueDiagnosticsSection(title: "Inference", lines: lines)
    }

    private static func crashSection() -> IssueDiagnosticsSection? {
        let fileManager = FileManager.default
        let reportsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let reportURLs = try? fileManager.contentsOfDirectory(
            at: reportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let nativReports = reportURLs
            .filter { $0.lastPathComponent.hasPrefix("Nativ") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
        guard !nativReports.isEmpty else {
            return IssueDiagnosticsSection(title: "Crash reports", lines: ["No Nativ crash reports found in ~/Library/Logs/DiagnosticReports."])
        }

        let formatter = ISO8601DateFormatter()
        var lines = nativReports.prefix(3).map { url -> String in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let timestamp = date.map { formatter.string(from: $0) } ?? "unknown date"
            return "\(url.lastPathComponent) (\(timestamp))"
        }
        if let newest = nativReports.first,
           let contents = try? String(contentsOf: newest, encoding: .utf8) {
            let excerpt = contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(12)
                .map(String.init)
            lines.append("— Newest report excerpt —")
            lines.append(contentsOf: excerpt)
        }
        return IssueDiagnosticsSection(title: "Crash reports", lines: lines)
    }
}

enum IssueReportBuilder {
    static let newIssueURL = "https://github.com/Blaizzy/nativ/issues/new"
    static let urlBodyCharacterBudget = 6_000

    static func markdown(
        category: IssueReportCategory,
        details: String,
        sections: [IssueDiagnosticsSection],
        serverOutput: [String]
    ) -> String {
        var parts: [String] = []
        parts.append("### Category\n\(category.displayName) issue")

        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("### What happened\n\(trimmedDetails.isEmpty ? "_No description provided._" : trimmedDetails)")

        if !sections.isEmpty {
            let body = sections.map { section in
                "**\(section.title)**\n" + section.lines.map { "- \($0)" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            parts.append("<details>\n<summary>Diagnostics</summary>\n\n\(body)\n\n</details>")
        }

        if !serverOutput.isEmpty {
            let log = serverOutput.joined(separator: "\n")
            parts.append("<details>\n<summary>Server output (last \(serverOutput.count) lines)</summary>\n\n```\n\(log)\n```\n\n</details>")
        }

        return redactingHomeDirectory(parts.joined(separator: "\n\n"))
    }

    static func redactingHomeDirectory(_ text: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        guard homePath.count > 1 else {
            return text
        }
        return text.replacingOccurrences(of: homePath, with: "~")
    }

    static func githubIssueURL(title: String, label: String, body: String) -> URL? {
        var urlBody = body
        if urlBody.count > urlBodyCharacterBudget {
            urlBody = balancedMarkdown(String(urlBody.prefix(urlBodyCharacterBudget)))
                + "\n\n_Diagnostics truncated — the full report was copied to your clipboard; paste it here to replace this body._"
        }

        var components = URLComponents(string: newIssueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: label),
            URLQueryItem(name: "body", value: urlBody)
        ]
        return components?.url
    }

    private static func balancedMarkdown(_ text: String) -> String {
        var result = text
        if (result.components(separatedBy: "```").count - 1) % 2 != 0 {
            result += "\n```"
        }
        let openDetails = result.components(separatedBy: "<details>").count - 1
        let closeDetails = result.components(separatedBy: "</details>").count - 1
        if openDetails > closeDetails {
            result += String(repeating: "\n</details>", count: openDetails - closeDetails)
        }
        return result
    }
}
