import Foundation
import NativServerKit

struct FormattedCount {
    let display: String
    let tooltip: String
}

struct StatsEntry {
    let label: String
    let value: String
    let tooltip: String?
}

enum NativFormatting {
    static let missingValue = "—"

    static func accessibleValue(_ value: String) -> String {
        value == missingValue ? String(localized: "Not available") : value
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let decimalFormatters: [Int: NumberFormatter] = {
        Dictionary(uniqueKeysWithValues: (0...4).map { digits in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            return (digits, formatter)
        })
    }()

    static func compactCount(_ value: Int) -> FormattedCount {
        let raw = integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
        let sign = value < 0 ? "-" : ""
        let absoluteValue = Double(abs(value))
        let units: [(suffix: String, factor: Double)] = [
            ("T", 1_000_000_000_000),
            ("B", 1_000_000_000),
            ("M", 1_000_000),
            ("K", 1_000),
        ]

        for unit in units where absoluteValue >= unit.factor {
            let scaled = absoluteValue / unit.factor
            let formatted = scaled >= 100
                ? scaled.formatted(.number.precision(.fractionLength(0))) + unit.suffix
                : scaled.formatted(.number.precision(.fractionLength(0...1))) + unit.suffix
            return FormattedCount(
                display: sign + formatted,
                tooltip: raw
            )
        }

        return FormattedCount(display: "\(value)", tooltip: raw)
    }

    static func rate(_ value: Double?) -> String {
        guard let value, value > 0, value.isFinite else {
            return missingValue
        }
        return String(format: "%.1f tok/s", value)
    }

    static func decimal(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value, value.isFinite else {
            return missingValue
        }

        let digits = min(max(fractionDigits, 0), 4)
        if let formatter = decimalFormatters[digits] {
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        return "\(value)"
    }

    static func integer(_ value: Int?) -> String {
        guard let value else {
            return missingValue
        }
        return integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func milliseconds(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value, value >= 0, value.isFinite else {
            return missingValue
        }
        return "\(decimal(value, fractionDigits: fractionDigits)) ms"
    }

    static func seconds(fromMilliseconds value: Int64?, fractionDigits: Int = 2) -> String {
        guard let value, value >= 0 else {
            return missingValue
        }
        return decimal(Double(value) / 1_000, fractionDigits: fractionDigits)
    }

    static func gigabytes(fromBytes value: Int64?, fractionDigits: Int = 1) -> String {
        guard let value, value >= 0 else {
            return missingValue
        }
        let gigabytes = Double(value) / Double(1024 * 1024 * 1024)
        return "\(decimal(gigabytes, fractionDigits: fractionDigits)) GB"
    }

    static func duration(_ value: Double?) -> String {
        guard let value, value >= 0, value.isFinite else {
            return missingValue
        }

        if value < 1 {
            return String(format: "%.2fs", value)
        }
        if value < 60 {
            return String(format: "%.1fs", value)
        }

        let totalSeconds = Int(value.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds)s"
    }

    static func elapsedDuration(_ value: TimeInterval) -> String {
        guard value.isFinite else {
            return "0s"
        }

        let totalSeconds = max(0, Int(value.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    static func clockDuration(_ value: TimeInterval) -> String {
        guard value.isFinite else {
            return "0:00"
        }

        let totalSeconds = max(0, Int(value.rounded(.down)))
        let duration = Duration.seconds(totalSeconds)
        if totalSeconds >= 3_600 {
            return duration.formatted(.time(pattern: .hourMinuteSecond))
        }
        return duration.formatted(.time(pattern: .minuteSecond))
    }

    static func gigabytes(_ value: Double) -> String {
        guard value.isFinite else {
            return missingValue
        }
        return String(format: "%.2f GB", value)
    }

    static func percent(_ value: Double) -> String {
        guard value.isFinite else {
            return missingValue
        }
        let percent = value <= 1 ? value * 100 : value
        return String(format: "%.1f%%", percent)
    }

    static func truncateModelName(_ value: String, maxLength: Int = 48) -> String {
        guard value.count > maxLength else {
            return value
        }

        let keep = max(8, (maxLength - 1) / 2)
        let prefix = value.prefix(keep)
        let suffix = value.suffix(keep)
        return "\(prefix)…\(suffix)"
    }

    static func timestamp(_ value: Double?) -> String {
        guard let value, value > 0 else {
            return missingValue
        }
        return Date(timeIntervalSince1970: value).formatted(
            date: .abbreviated,
            time: .shortened
        )
    }

    static func titleizedIdentifier(_ value: String?) -> String {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return missingValue
        }

        return rawValue
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { segment in
                segment.prefix(1).uppercased() + segment.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

enum NativStats {
    static func sessionEntries(_ metrics: NativMetrics) -> [StatsEntry] {
        [
            statsEntry("Requests completed", metrics.summary.requestsCompleted),
            statsEntry("Requests failed", metrics.summary.requestsFailed),
            statsEntry("In flight", metrics.summary.inFlight),
            statsEntry("Prompt tokens", metrics.summary.promptTokensTotal),
            statsEntry("Generated tokens", metrics.summary.generatedTokensTotal),
            statsEntry("Total processed tokens", metrics.summary.totalProcessedTokens),
            StatsEntry(
                label: "Avg decode speed",
                value: NativFormatting.rate(metrics.summary.averageDecodeTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Avg request speed",
                value: NativFormatting.rate(metrics.summary.averageRequestTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Uptime",
                value: NativFormatting.duration(metrics.summary.uptimeSeconds),
                tooltip: nil
            ),
        ]
    }

    static func allTimeEntries(_ allTimeStats: NativAllTimeStats) -> [StatsEntry] {
        [
            statsEntry("Requests completed", allTimeStats.requestsCompleted),
            statsEntry("Requests failed", allTimeStats.requestsFailed),
            statsEntry("Prompt tokens", allTimeStats.promptTokensTotal),
            statsEntry("Generated tokens", allTimeStats.generatedTokensTotal),
            statsEntry("Total processed tokens", allTimeStats.totalProcessedTokens),
            StatsEntry(
                label: "Avg decode speed",
                value: NativFormatting.rate(allTimeStats.averageDecodeTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Avg request speed",
                value: NativFormatting.rate(allTimeStats.averageRequestTokensPerSecond),
                tooltip: nil
            ),
        ]
    }

    static func latestRequestEntries(_ latest: NativLatestRequest) -> [StatsEntry] {
        let fullModel = latest.model ?? missingValue
        var entries: [StatsEntry] = [
            StatsEntry(
                label: "Model",
                value: NativFormatting.truncateModelName(fullModel),
                tooltip: fullModel
            ),
            StatsEntry(label: "Endpoint", value: latest.endpoint ?? NativFormatting.missingValue, tooltip: nil),
            statsEntry("Prompt tokens", latest.promptTokens),
            statsEntry("Completion tokens", latest.completionTokens),
            statsEntry("Generated tokens", latest.generatedTokens),
            statsEntry("Total tokens", latest.promptTokens + latest.generatedTokens),
            StatsEntry(
                label: "Time to first token",
                value: NativFormatting.duration(latest.timeToFirstTokenSeconds),
                tooltip: nil
            ),
            StatsEntry(
                label: "Prefill speed",
                value: NativFormatting.rate(latest.prefillTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Decode speed",
                value: NativFormatting.rate(latest.decodeTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Elapsed time",
                value: NativFormatting.duration(latest.requestElapsedSeconds),
                tooltip: nil
            ),
        ]

        if let peakMemoryGB = latest.peakMemoryGB {
            entries.append(StatsEntry(
                label: "Peak memory",
                value: NativFormatting.gigabytes(peakMemoryGB),
                tooltip: nil
            ))
        }
        if latest.imageCount > 0 || latest.audioCount > 0 {
            entries.append(StatsEntry(
                label: "Media",
                value: "\(latest.imageCount) images, \(latest.audioCount) audio",
                tooltip: nil
            ))
        }
        if latest.thinkingEnabled || latest.toolCalls || latest.apcEnabled {
            entries.append(StatsEntry(label: "Flags", value: latestFlags(latest), tooltip: nil))
        }

        return entries
    }

    static func runtimeEntries(_ runtime: NativRuntimeSnapshot) -> [StatsEntry] {
        let loadedModel = runtime.displayLoadedModel
        var entries: [StatsEntry] = [
            StatsEntry(
                label: "Loaded model",
                value: NativFormatting.truncateModelName(loadedModel),
                tooltip: loadedModel
            ),
            statsEntry("Queue depth", runtime.requestQueueDepth),
            StatsEntry(label: "Batching", value: runtime.continuousBatchingEnabled ? "On" : "Off", tooltip: nil),
            StatsEntry(label: "APC", value: runtime.apc.enabled ? "On" : "Off", tooltip: nil),
        ]

        if let contextLimit = runtime.effectiveContextLimit ?? runtime.configuredContextLimit ?? runtime.loadedContextSize {
            entries.append(statsEntry("Context limit", contextLimit))
        }
        if let loadedAdapter = runtime.loadedAdapter {
            entries.append(StatsEntry(
                label: "Adapter",
                value: NativFormatting.truncateModelName(loadedAdapter),
                tooltip: loadedAdapter
            ))
        }
        if let toolParser = runtime.loadedToolParser {
            entries.append(StatsEntry(label: "Tool parser", value: toolParser, tooltip: nil))
        }
        if runtime.apc.enabled {
            if let tokenHitRate = runtime.apc.tokenHitRate {
                entries.append(StatsEntry(
                    label: "APC token hit rate",
                    value: NativFormatting.percent(tokenHitRate),
                    tooltip: nil
                ))
            }
            if let matchedTokens = runtime.apc.matchedTokens {
                entries.append(statsEntry("APC matched tokens", matchedTokens))
            }
            if let diskHits = runtime.apc.diskHits {
                entries.append(statsEntry("APC disk hits", diskHits))
            }
        }

        return entries
    }

    static func modelEntries(_ model: NativModelMetrics) -> [StatsEntry] {
        [
            statsEntry("Requests completed", model.requestsCompleted),
            statsEntry("Requests failed", model.requestsFailed),
            statsEntry("Streamed requests", model.streamingRequests),
            statsEntry("Prompt tokens", model.promptTokensTotal),
            statsEntry("Generated tokens", model.generatedTokensTotal),
            statsEntry("Total processed tokens", model.totalProcessedTokens),
            StatsEntry(
                label: "Avg request speed",
                value: NativFormatting.rate(model.averageRequestTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Avg decode speed",
                value: NativFormatting.rate(model.averageDecodeTokensPerSecond),
                tooltip: nil
            ),
            StatsEntry(
                label: "Last request",
                value: NativFormatting.timestamp(model.lastRequestAt),
                tooltip: nil
            ),
        ]
    }

    static func statsEntry(_ label: String, _ value: Int) -> StatsEntry {
        let formatted = NativFormatting.compactCount(value)
        return StatsEntry(label: label, value: formatted.display, tooltip: formatted.tooltip)
    }

    private static func latestFlags(_ latest: NativLatestRequest) -> String {
        var flags: [String] = []
        if latest.thinkingEnabled {
            flags.append("thinking")
        }
        if latest.toolCalls {
            flags.append("tools")
        }
        if latest.apcEnabled {
            flags.append("APC")
        }
        return flags.isEmpty ? NativFormatting.missingValue : flags.joined(separator: ", ")
    }
}

struct NativAllTimeStats: Codable, Sendable {
    static let empty = NativAllTimeStats()

    var requestsCompleted: Int = 0
    var requestsFailed: Int = 0
    var promptTokensTotal: Int = 0
    var completionTokensTotal: Int = 0
    var generatedTokensTotal: Int = 0
    var decodeTokensTotal: Int?
    var requestTimeTotalSeconds: Double = 0
    var decodeTimeTotalSeconds: Double = 0
    var lastUpdated: Date?

    var totalProcessedTokens: Int {
        promptTokensTotal + generatedTokensTotal
    }

    var hasValues: Bool {
        requestsCompleted > 0 ||
            requestsFailed > 0 ||
            promptTokensTotal > 0 ||
            completionTokensTotal > 0 ||
            generatedTokensTotal > 0 ||
            requestTimeTotalSeconds > 0 ||
            decodeTimeTotalSeconds > 0
    }

    var averageDecodeTokensPerSecond: Double? {
        let measuredTokens = decodeTokensTotal ?? generatedTokensTotal
        guard measuredTokens > 0, decodeTimeTotalSeconds > 0 else {
            return nil
        }
        return Double(measuredTokens) / decodeTimeTotalSeconds
    }

    var averageRequestTokensPerSecond: Double? {
        guard completionTokensTotal > 0, requestTimeTotalSeconds > 0 else {
            return nil
        }
        return Double(completionTokensTotal) / requestTimeTotalSeconds
    }

    static func load(from databaseURL: URL = NativAnalyticsStore.defaultDatabaseURL()) -> NativAllTimeStats {
        NativAnalyticsStore(databaseURL: databaseURL)
            .fetchSummary(range: .allTime)
            .asAllTimeStats
    }

    static func removeLegacyStorage() {
        let url = legacyStorageURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func legacyStorageURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.local.Nativ"
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("NativStats.plist")
    }
}
