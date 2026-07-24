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
            "Thinking: \(settings.thinkingEnabled ? "on" : "off")",
            "Launch arguments: \(settings.launchArguments.joined(separator: " "))"
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
        var lines: [String] = []
        if let metrics = model.metrics {
            lines.append(contentsOf: NativStats.sessionEntries(metrics).map { "\($0.label): \($0.value)" })
            if let latest = metrics.latest {
                lines.append("— Latest request —")
                lines.append(contentsOf: NativStats.latestRequestEntries(latest).map { "\($0.label): \($0.value)" })
            }
            lines.append("— Runtime —")
            lines.append(contentsOf: NativStats.runtimeEntries(metrics.server).map { "\($0.label): \($0.value)" })
        } else if let error = model.lastMetricsError {
            lines.append("Metrics unavailable: \(error)")
        }
        if model.allTimeStats.hasValues {
            lines.append("— All-time —")
            lines.append(contentsOf: NativStats.allTimeEntries(model.allTimeStats).map { "\($0.label): \($0.value)" })
        }
        return lines.isEmpty ? nil : IssueDiagnosticsSection(title: "Inference", lines: lines)
    }

    private static func crashSection() -> IssueDiagnosticsSection? {
        let nativReports = newestNativReports()
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
            if let summary = parsedCrashSummary(contents) {
                lines.append("— Newest report —")
                lines.append(contentsOf: summary)
                lines.append("(full report copied to your clipboard)")
            } else {
                let excerpt = contents
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(12)
                    .map(String.init)
                lines.append("— Newest report excerpt —")
                lines.append(contentsOf: excerpt)
            }
        }
        return IssueDiagnosticsSection(title: "Crash reports", lines: lines)
    }

    static func latestCrashRawReport() -> String? {
        guard let newest = newestNativReports().first,
              let contents = try? String(contentsOf: newest, encoding: .utf8) else {
            return nil
        }
        return IssueReportBuilder.redactingHomeDirectory(contents)
    }

    private static func newestNativReports() -> [URL] {
        let fileManager = FileManager.default
        let reportsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let reportURLs = try? fileManager.contentsOfDirectory(
            at: reportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return reportURLs
            .filter { $0.lastPathComponent.hasPrefix("Nativ") }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private static func parsedCrashSummary(_ contents: String) -> [String]? {
        let parts = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let bodyData = String(parts[1]).data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            return nil
        }

        var lines: [String] = []
        if let exception = payload["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "unknown"
            if let signal = exception["signal"] as? String {
                lines.append("Exception: \(type) (\(signal))")
            } else {
                lines.append("Exception: \(type)")
            }
        }
        if let termination = payload["termination"] as? [String: Any] {
            if let indicator = termination["indicator"] as? String {
                lines.append("Reason: \(indicator)")
            } else if let namespace = termination["namespace"] as? String {
                let code = termination["code"] as? Int
                lines.append("Reason: \(namespace)\(code.map { " code \($0)" } ?? "")")
            }
        }

        let images = payload["usedImages"] as? [[String: Any]] ?? []
        if let threads = payload["threads"] as? [[String: Any]],
           let crashed = threads.first(where: { ($0["triggered"] as? Bool) == true }),
           let frames = crashed["frames"] as? [[String: Any]], !frames.isEmpty {
            lines.append("Crashed thread:")
            for (index, frame) in frames.prefix(20).enumerated() {
                let imageIndex = frame["imageIndex"] as? Int
                let imageName = imageIndex.flatMap { i -> String? in
                    guard i >= 0, i < images.count else { return nil }
                    return images[i]["name"] as? String
                } ?? "?"
                let detail: String
                if let symbol = frame["symbol"] as? String {
                    detail = "\(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
                } else {
                    detail = "0x… + \(frame["imageOffset"] as? Int ?? 0)"
                }
                lines.append("\(index)  \(imageName)  \(detail)")
            }
        }

        return lines.isEmpty ? nil : lines
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
