import AppKit
import SwiftUI
import WidgetKit

private struct NativWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: NativWidgetSnapshot
}

private struct NativWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> NativWidgetEntry {
        NativWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (NativWidgetEntry) -> Void
    ) {
        completion(NativWidgetEntry(
            date: Date(),
            snapshot: context.isPreview
                ? .placeholder
                : NativWidgetSnapshotStore.load()
        ))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NativWidgetEntry>) -> Void
    ) {
        let entry = NativWidgetEntry(
            date: Date(),
            snapshot: NativWidgetSnapshotStore.load()
        )
        let nextUpdate = Calendar.current.date(
            byAdding: .minute,
            value: 1,
            to: entry.date
        ) ?? entry.date.addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

private enum NativWidgetPalette {
    static let blue = Color(red: 0.18, green: 0.55, blue: 0.98)
    static let purple = Color(red: 0.47, green: 0.36, blue: 0.96)
    static let orange = Color(red: 0.98, green: 0.49, blue: 0.14)
    static let teal = Color(red: 0.18, green: 0.74, blue: 0.72)
    static let prompt = Color(red: 0.31, green: 0.72, blue: 0.77)
    static let generated = Color(red: 0.45, green: 0.55, blue: 0.92)
}

private struct NativSessionWidgetView: View {
    let entry: NativWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var session: NativWidgetSessionSnapshot {
        entry.snapshot.session
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                compactContent
            } else {
                expandedContent
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    NativWidgetPalette.blue.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Spacer(minLength: 0)

            Text("Processed tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(NativWidgetFormat.compact(session.processedTokens))
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()

            NativWidgetActivityBars(
                values: session.tokenActivity,
                referenceDate: entry.date,
                bucketCount: 18,
                maximumBarHeight: 28
            )
            .frame(height: 30, alignment: .bottom)

            HStack {
                metric("Requests", NativWidgetFormat.compact(session.completedRequests))
                Spacer()
                metric("Decode", NativWidgetFormat.rate(
                    session.averageDecodeTokensPerSecond
                ))
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Processed tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NativWidgetFormat.compact(session.processedTokens))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                }

                Spacer()

                metric(
                    "Average decode",
                    NativWidgetFormat.rate(session.averageDecodeTokensPerSecond),
                    alignment: .trailing
                )
            }

            HStack(spacing: 16) {
                tokenLegend(
                    "Prompt",
                    value: session.promptTokens,
                    color: NativWidgetPalette.prompt
                )
                tokenLegend(
                    "Generated",
                    value: session.generatedTokens,
                    color: NativWidgetPalette.generated
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Recent token activity")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                    Text("Last ~10 min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                NativWidgetActivityBars(
                    values: session.tokenActivity,
                    referenceDate: entry.date,
                    bucketCount: 30,
                    maximumBarHeight: family == .systemLarge ? 72 : 40
                )
                .frame(
                    height: family == .systemLarge ? 74 : 42,
                    alignment: .bottom
                )
            }

            Divider()

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 10
            ) {
                metric(
                    "Completed requests",
                    NativWidgetFormat.compact(session.completedRequests)
                )
                metric(
                    "Failed requests",
                    NativWidgetFormat.compact(session.failedRequests)
                )
                metric(
                    "In flight",
                    NativWidgetFormat.compact(session.inFlightRequests)
                )
                metric(
                    "Uptime",
                    NativWidgetFormat.duration(session.uptimeSeconds)
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NativWidgetLogo(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Nativ Session")
                    .font(.headline)
                Text(session.modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Circle()
                    .fill(session.isRunning ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(session.status)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
    }

    private func tokenLegend(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(NativWidgetFormat.compact(value))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(
        _ title: String,
        _ value: String,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }
}

private struct NativSystemWidgetView: View {
    let entry: NativWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var system: NativWidgetSystemSnapshot {
        entry.snapshot.system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NativWidgetLogo(size: 24)
                Text("System Stats")
                    .font(.headline)
                Spacer()
                Text(entry.snapshot.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if family == .systemSmall {
                compactSystem
            } else {
                expandedSystem
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    NativWidgetPalette.purple.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var compactSystem: some View {
        VStack(spacing: 10) {
            systemRow(
                title: "CPU",
                icon: "cpu",
                usage: system.cpuUsage,
                history: system.cpuHistory,
                tint: NativWidgetPalette.blue
            )
            systemRow(
                title: "GPU",
                icon: "display",
                usage: system.gpuUsage,
                history: system.gpuHistory,
                tint: NativWidgetPalette.purple
            )
            systemRow(
                title: "RAM",
                icon: "memorychip",
                usage: system.memoryUsage,
                history: system.memoryHistory,
                tint: NativWidgetPalette.orange
            )
        }
    }

    private var expandedSystem: some View {
        HStack(spacing: 12) {
            systemCard(
                title: "CPU",
                icon: "cpu",
                usage: system.cpuUsage,
                detail: "Processor",
                history: system.cpuHistory,
                tint: NativWidgetPalette.blue
            )
            systemCard(
                title: "GPU",
                icon: "display",
                usage: system.gpuUsage,
                detail: "Graphics",
                history: system.gpuHistory,
                tint: NativWidgetPalette.purple
            )
            systemCard(
                title: "RAM",
                icon: "memorychip",
                usage: system.memoryUsage,
                detail: NativWidgetFormat.memory(
                    system.usedMemoryBytes,
                    total: system.totalMemoryBytes
                ),
                history: system.memoryHistory,
                tint: NativWidgetPalette.orange
            )
        }
    }

    private func systemRow(
        title: String,
        icon: String,
        usage: Double?,
        history: [Double],
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .font(.caption.weight(.semibold))
            NativWidgetSparkline(values: history, tint: tint)
                .frame(height: 22)
            Text(NativWidgetFormat.percent(usage))
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func systemCard(
        title: String,
        icon: String,
        usage: Double?,
        detail: String,
        history: [Double],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Spacer()
                Text(NativWidgetFormat.percent(usage))
                    .font(.headline.monospacedDigit())
            }
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            NativWidgetSparkline(values: history, tint: tint)
                .frame(height: 40)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.09), in: .rect(cornerRadius: 12))
    }
}

private enum NativWidgetAssets {
    static let logo: NSImage? = {
        let extensionURL = Bundle.main.bundleURL
        let appURL = extensionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if appURL.pathExtension == "app" {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.isTemplate = false
            return icon
        }
        return NSImage(named: "MenuBarLogo")
    }()
}

private struct NativWidgetLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let logo = NativWidgetAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(NativWidgetPalette.blue)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Nativ")
    }
}

private struct NativWidgetActivityBars: View {
    let values: [NativWidgetTokenActivitySample]
    let referenceDate: Date
    let bucketCount: Int
    let maximumBarHeight: CGFloat

    private struct Bucket {
        var promptTokens = 0
        var generatedTokens = 0

        var totalTokens: Int {
            promptTokens + generatedTokens
        }
    }

    private let bucketDuration: TimeInterval = 20

    private var plottedValues: [Bucket] {
        var buckets = Array(
            repeating: Bucket(),
            count: max(bucketCount, 1)
        )
        let currentBucketStart =
            floor(referenceDate.timeIntervalSince1970 / bucketDuration)
            * bucketDuration
        let windowStart = currentBucketStart
            - (Double(buckets.count - 1) * bucketDuration)

        for sample in values {
            let elapsed = sample.recordedAt.timeIntervalSince1970 - windowStart
            let index = Int(floor(elapsed / bucketDuration))
            guard buckets.indices.contains(index) else {
                continue
            }
            buckets[index].promptTokens += sample.promptTokens
            buckets[index].generatedTokens += sample.generatedTokens
        }
        return buckets
    }

    private var maximumValue: CGFloat {
        CGFloat(max(plottedValues.map(\.totalTokens).max() ?? 0, 1))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(plottedValues.enumerated()), id: \.offset) { _, sample in
                activityBar(sample)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent token activity")
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private func activityBar(_ sample: Bucket) -> some View {
        let total = sample.totalTokens
        if total == 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(NativWidgetPalette.prompt.opacity(0.18))
                .frame(maxWidth: .infinity)
                .frame(height: 2)
        } else {
            let hasBothSegments =
                sample.promptTokens > 0 && sample.generatedTokens > 0
            let barHeight = max(
                hasBothSegments ? 6 : 4,
                maximumBarHeight * CGFloat(total) / maximumValue
            )
            let promptHeight = segmentHeight(
                value: sample.promptTokens,
                total: total,
                barHeight: barHeight,
                hasBothSegments: hasBothSegments
            )
            let generatedHeight = barHeight - promptHeight

            VStack(spacing: 0) {
                if generatedHeight > 0 {
                    Rectangle()
                        .fill(NativWidgetPalette.generated.opacity(0.95))
                        .frame(height: generatedHeight)
                }
                if promptHeight > 0 {
                    Rectangle()
                        .fill(NativWidgetPalette.prompt.opacity(0.95))
                        .frame(height: promptHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func segmentHeight(
        value: Int,
        total: Int,
        barHeight: CGFloat,
        hasBothSegments: Bool
    ) -> CGFloat {
        guard value > 0 else {
            return 0
        }
        guard hasBothSegments else {
            return barHeight
        }
        let proportionalHeight = barHeight * CGFloat(value) / CGFloat(total)
        return min(max(proportionalHeight, 2), barHeight - 2)
    }

    private var accessibilityValue: String {
        let promptTokens = plottedValues.reduce(0) {
            $0 + $1.promptTokens
        }
        let generatedTokens = plottedValues.reduce(0) {
            $0 + $1.generatedTokens
        }
        return "\(promptTokens) prompt and \(generatedTokens) generated tokens over the last 10 minutes"
    }
}

private struct NativWidgetSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let samples = values.count > 1 ? values : [0, 0]
            let denominator = CGFloat(max(samples.count - 1, 1))
            var line = Path()
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))

            for (index, rawValue) in samples.enumerated() {
                let x = size.width * CGFloat(index) / denominator
                let value = min(max(rawValue, 0), 1)
                let y = size.height - (size.height * CGFloat(value))
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    line.move(to: point)
                    area.addLine(to: point)
                } else {
                    line.addLine(to: point)
                    area.addLine(to: point)
                }
            }

            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.16)))
            context.stroke(
                line,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

private enum NativWidgetFormat {
    static func compact(_ value: Int) -> String {
        switch abs(value) {
        case 1_000_000...:
            String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            String(format: "%.1fK", Double(value) / 1_000)
        default:
            "\(value)"
        }
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    static func rate(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f tok/s", value) : "--"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0s" }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(total % 60)s"
    }

    static func memory(_ used: UInt64, total: UInt64) -> String {
        guard total > 0 else { return "Unavailable" }
        let divisor = Double(1024 * 1024 * 1024)
        return String(
            format: "%.1f / %.0f GB",
            Double(used) / divisor,
            Double(total) / divisor
        )
    }
}

struct NativSessionWidget: Widget {
    let kind = "NativSessionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NativWidgetProvider()) { entry in
            NativSessionWidgetView(entry: entry)
        }
        .configurationDisplayName("Nativ Session")
        .description("Server status, token activity, and request performance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NativSystemWidget: Widget {
    let kind = "NativSystemWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NativWidgetProvider()) { entry in
            NativSystemWidgetView(entry: entry)
        }
        .configurationDisplayName("Nativ System")
        .description("Live CPU, GPU, and unified memory usage from Nativ.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct NativWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NativSessionWidget()
        NativSystemWidget()
    }
}
