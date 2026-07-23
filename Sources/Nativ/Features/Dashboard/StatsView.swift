import Charts
import NativServerKit
import SwiftUI

struct StatsView: View {
    @ObservedObject var model: NativModel
    let dashboard: DashboardViewModel

    var body: some View {
        DashboardContentView(
            modelState: DashboardModelState(model: model),
            dashboard: dashboard
        )
        .equatable()
    }

    private var sessionSubtitle: String? {
        if let _ = model.metrics {
            return nil
        }
        if model.isRunning {
            return model.unavailableMetricsText
        }
        return "Server is off. Live metrics are paused."
    }

    private var sessionCards: [SessionCardValue] {
        let metrics = model.metrics

        return [
            makeSessionCard(
                title: "Processed tokens",
                rawCount: metrics?.summary.totalProcessedTokens
            ),
            makeSessionCard(
                title: "Prompt tokens",
                rawCount: metrics?.summary.promptTokensTotal
            ),
            makeSessionCard(
                title: "Generated tokens",
                rawCount: metrics?.summary.generatedTokensTotal
            ),
            makeSessionCard(
                title: "Completed requests",
                rawCount: metrics?.summary.requestsCompleted
            ),
            SessionCardValue(
                title: "Decode speed",
                value: NativFormatting.rate(
                    metrics?.summary.averageDecodeTokensPerSecond
                ),
                help: nil
            ),
            SessionCardValue(
                title: "Request speed",
                value: NativFormatting.rate(
                    metrics?.summary.averageRequestTokensPerSecond
                ),
                help: nil
            ),
            SessionCardValue(
                title: "Server uptime",
                value: NativFormatting.duration(metrics?.summary.uptimeSeconds),
                help: nil
            ),
        ]
    }

    private func makeSessionCard(title: String, rawCount: Int?) -> SessionCardValue {
        guard let rawCount else {
            return SessionCardValue(title: title, value: "--", help: nil)
        }
        let formatted = NativFormatting.compactCount(rawCount)
        return SessionCardValue(
            title: title,
            value: formatted.display,
            help: formatted.tooltip
        )
    }
}

private struct DashboardModelState: Equatable {
    let isRunning: Bool
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    let analyticsDatabaseURL: URL
    let loadedModelID: String?
    let historicalMetricsRevision: DashboardMetricsRevision?

    @MainActor
    init(model: NativModel) {
        isRunning = model.isRunning
        modelSearchPath = model.settings.modelSearchPath
        additionalModelSearchPaths = model.settings.normalized().additionalModelSearchPaths
        analyticsDatabaseURL = model.analyticsDatabaseURL
        loadedModelID = model.metrics?.server.loadedModel
        historicalMetricsRevision = model.metrics.map {
            DashboardMetricsRevision(
                completedRequests: $0.summary.requestsCompleted,
                failedRequests: $0.summary.requestsFailed
            )
        }
    }
}

private struct DashboardContentView: View, Equatable {
    let modelState: DashboardModelState
    @ObservedObject var dashboard: DashboardViewModel
    @FocusState private var isModelSearchFocused: Bool
    @State private var selectedChartMetric: DashboardOverviewMetric = .tokens
    @State private var isActivityExpanded = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modelState == rhs.modelState && lhs.dashboard === rhs.dashboard
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                filterBar
                overviewCards
                analyticsGrid
                modelPerformanceSection
                recentRequestsSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            isModelSearchFocused = false
        }
        .onAppear {
            syncDashboardState(scanModels: true, reloadHistory: true)
        }
        .onChange(of: modelState.modelSearchPath) { _, _ in
            syncDashboardState(scanModels: true, reloadHistory: false)
        }
        .onChange(of: modelState.analyticsDatabaseURL) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: false)
        }
        .onChange(of: modelState.loadedModelID) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: false)
        }
        .onChange(of: modelState.historicalMetricsRevision) { oldRevision, newRevision in
            guard oldRevision != nil, newRevision != nil else { return }
            syncDashboardState(scanModels: false, reloadHistory: true)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Analytics")
                    .font(.title2.weight(.semibold))
                Text("Monitor token consumption, request volume, and model performance across this workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Circle()
                    .fill(modelState.isRunning ? DashboardPalette.positive : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(modelState.isRunning ? "Live" : "Offline")
                    .font(.caption.weight(.semibold))

                Button {
                    dashboard.reloadHistorical()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("Refresh analytics")
                .disabled(dashboard.isLoadingHistory)
            }
            .fixedSize()
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filtersRow
                Spacer(minLength: 16)
                Text(lastUpdatedLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 10) {
                filtersRow
                Text(lastUpdatedLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .dashboardPanelStyle(cornerRadius: 12)
    }

    private var overviewCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            AnalyticsMetricCard(
                title: "Total tokens",
                value: compact(dashboard.historicalSummary.totalProcessedTokens),
                detail: "\(compact(dashboard.historicalSummary.promptTokensTotal)) input · \(compact(dashboard.historicalSummary.generatedTokensTotal)) output",
                icon: "number",
                tint: DashboardPalette.accent,
                isSelected: selectedChartMetric == .tokens
            ) {
                selectedChartMetric = .tokens
            }
            AnalyticsMetricCard(
                title: "Requests",
                value: compact(totalRequests),
                detail: requestDetail,
                icon: "arrow.up.arrow.down",
                tint: DashboardPalette.indigo,
                isSelected: selectedChartMetric == .requests
            ) {
                selectedChartMetric = .requests
            }
            AnalyticsMetricCard(
                title: "Success rate",
                value: successRateLabel,
                detail: dashboard.historicalSummary.requestsFailed == 0
                    ? "No failed requests"
                    : "\(compact(dashboard.historicalSummary.requestsFailed)) failed",
                icon: "checkmark.circle",
                tint: DashboardPalette.positive,
                isSelected: selectedChartMetric == .successRate
            ) {
                selectedChartMetric = .successRate
            }
            AnalyticsMetricCard(
                title: "Decode speed",
                value: NativFormatting.rate(
                    dashboard.historicalSummary.averageDecodeTokensPerSecond
                ),
                detail: "Average across requests",
                icon: "gauge.with.dots.needle.67percent",
                tint: DashboardPalette.orange,
                isSelected: selectedChartMetric == .decodeSpeed
            ) {
                selectedChartMetric = .decodeSpeed
            }
        }
    }

    private var analyticsGrid: some View {
        Group {
            if isActivityExpanded {
                userActivityPanel
                    .frame(maxWidth: .infinity)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        analyticsChart
                            .frame(minWidth: 680, maxWidth: .infinity)

                        userActivityPanel
                            .frame(width: 350)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        analyticsChart
                        userActivityPanel
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.24), value: isActivityExpanded)
    }

    private var analyticsChart: some View {
        TokenUsagePanel(
            metric: selectedChartMetric,
            points: dashboard.bucketPoints,
            modelPoints: dashboard.modelTokenPoints,
            range: dashboard.selectedRange,
            showsAllModels: dashboard.appliedModelID == DashboardViewModel.ModelOption.allID
        )
        .frame(maxWidth: .infinity)
    }

    private var userActivityPanel: some View {
        UserActivityPanel(
            points: dashboard.hourlyActivityPoints,
            range: dashboard.selectedRange,
            isExpanded: isActivityExpanded,
            onToggleExpansion: {
                isActivityExpanded.toggle()
            }
        )
    }

    private var modelPerformanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnalyticsSectionHeader(
                title: "Model performance",
                subtitle: "Usage and throughput by model for the selected period"
            )

            ModelPerformanceTable(
                rows: dashboard.modelPerformance,
                modelColorDomain: chartModelColorDomain,
                searchFocus: $isModelSearchFocused
            )

            if let localModelError = dashboard.localModelError {
                Text(localModelError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentRequestsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnalyticsSectionHeader(
                title: "Recent requests",
                subtitle: "Select a request to inspect latency, throughput, and memory details"
            )

            DashboardRecentRequestsTable(requests: dashboard.recentRequestEvents)
        }
    }

    private var leadingModelIDs: [String] {
        Array(dashboard.modelPerformance.prefix(modelOverviewLimit).map(\.modelID))
    }

    private var chartModelColorDomain: [String] {
        var modelIDs = leadingModelIDs
        if dashboard.modelPerformance.count > modelOverviewLimit {
            modelIDs.append("Other")
        }
        return DashboardModelColorScale.domain(for: modelIDs)
    }

    private var modelOverviewLimit: Int { 12 }

    private var totalRequests: Int {
        dashboard.historicalSummary.requestsCompleted + dashboard.historicalSummary.requestsFailed
    }

    private var successRateLabel: String {
        guard totalRequests > 0 else { return "--" }
        return NativFormatting.percent(
            Double(dashboard.historicalSummary.requestsCompleted) / Double(totalRequests)
        )
    }

    private var requestDetail: String {
        let completed = "\(compact(dashboard.historicalSummary.requestsCompleted)) completed"
        guard dashboard.historicalSummary.ttftSampleCount > 0 else {
            return completed
        }
        let ttft = NativFormatting.milliseconds(
            dashboard.historicalSummary.averageTTFTMilliseconds
        )
        return "\(completed) · \(ttft) TTFT"
    }

    private var lastUpdatedLabel: String {
        guard let date = dashboard.historicalSummary.lastUpdatedAt else {
            return dashboard.isLoadingHistory ? "Refreshing…" : "Waiting for analytics data"
        }
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func compact(_ value: Int) -> String {
        NativFormatting.compactCount(value).display
    }

    private var filtersRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modelFilter.frame(width: 300)
                periodFilter.frame(width: 430)
            }

            VStack(alignment: .leading, spacing: 10) {
                modelFilter.frame(maxWidth: .infinity)
                periodFilter.frame(maxWidth: .infinity)
            }
        }
    }

    private var modelFilter: some View {
        DashboardPickerContainer(title: "Model") {
            Picker("Model", selection: $dashboard.selectedModelID) {
                ForEach(dashboard.availableModels) { option in
                    Text(option.displayTitle).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var periodFilter: some View {
        DashboardPickerContainer(title: "Period") {
            DashboardPeriodSelector(selection: $dashboard.selectedRange)
        }
    }

    private func syncDashboardState(scanModels: Bool, reloadHistory: Bool) {
        dashboard.updateAnalyticsDatabaseURL(modelState.analyticsDatabaseURL)
        dashboard.updatePreferredModelID(modelState.loadedModelID)
        if scanModels {
            dashboard.scanModels(
                at: modelState.modelSearchPath,
                additionalPaths: modelState.additionalModelSearchPaths
            )
        }
        if reloadHistory {
            dashboard.reloadHistorical()
        }
    }
}

private struct DashboardMetricsRevision: Equatable {
    let completedRequests: Int
    let failedRequests: Int
}

private struct AnalyticsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AnalyticsMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark" : "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            isSelected || isHovered
                                ? tint
                                : Color.secondary.opacity(0.5)
                        )
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .dashboardPanelStyle(cornerRadius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? tint.opacity(0.045) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? tint : (isHovered ? tint.opacity(0.55) : Color.clear),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.012 : 1)
        .shadow(
            color: isHovered ? tint.opacity(0.14) : Color.clear,
            radius: isHovered ? 9 : 0,
            y: isHovered ? 4 : 0
        )
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .help("Show \(title.lowercased()) chart")
        .accessibilityValue(isSelected ? "Selected" : "Select to update chart")
    }
}

private struct UserActivityPanel: View {
    private static let timeBlocks = [0, 4, 8, 12, 16, 20]

    private struct HeatmapCell: Identifiable {
        let id: String
        let count: Int
        let help: String
    }

    private struct HoverableHeatmapCell: View {
        let fillColor: Color
        let borderColor: Color
        let width: CGFloat
        let help: String

        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

            shape
                .fill(fillColor)
                .overlay {
                    if isHovered {
                        shape.fill(DashboardPalette.accent.opacity(0.12))
                    }
                }
                .frame(width: width, height: width)
                .overlay {
                    shape.stroke(
                        isHovered ? DashboardPalette.accent.opacity(0.9) : borderColor,
                        lineWidth: isHovered ? 1.1 : 0.45
                    )
                }
                .scaleEffect(isHovered ? 1.08 : 1)
                .shadow(
                    color: isHovered ? DashboardPalette.accent.opacity(0.22) : .clear,
                    radius: isHovered ? 5 : 0
                )
                .overlay(alignment: .top) {
                    if isHovered {
                        Text(help)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(DashboardPalette.panelStroke, lineWidth: 0.6)
                            }
                            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
                            .offset(y: -34)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                            .allowsHitTesting(false)
                    }
                }
                .zIndex(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.14), value: isHovered)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .help(help)
                .accessibilityLabel(help)
        }
    }

    private struct HeatmapRow: Identifiable {
        let id: String
        let label: String
        let cells: [HeatmapCell]
    }

    private struct HeatmapLayout {
        let columnLabels: [String]
        let rows: [HeatmapRow]
        let rowLabelWidth: CGFloat
        let cellWidth: CGFloat
        let spacing: CGFloat
    }

    let points: [DashboardViewModel.ActivityPoint]
    let range: DashboardViewModel.RangeOption
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AnalyticsSectionHeader(
                    title: "User activity",
                    subtitle: "Request density · \(rangeLabel)"
                )
                Spacer(minLength: 8)
                Button(action: onToggleExpansion) {
                    Image(systemName: isExpanded
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse user activity" : "Expand user activity")
            }

            activityLegend
            heatmap
            periodBreakdown
        }
        .padding(18)
        .dashboardPanelStyle(cornerRadius: 14)
        .animation(.snappy(duration: 0.24), value: isExpanded)
    }

    private var activityLegend: some View {
        HStack(spacing: 13) {
            ActivityLegendItem(title: "Low", color: DashboardPalette.accent.opacity(0.44))
            ActivityLegendItem(title: "Medium", color: DashboardPalette.accent.opacity(0.63))
            ActivityLegendItem(title: "High", color: DashboardPalette.accent)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var heatmap: some View {
        let layout = heatmapLayout
        let maximumCount = layout.rows.flatMap(\.cells).map(\.count).max() ?? 0

        return Group {
            if range == .last24Hours {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    dailyHeatmapContent(layout: layout, maximumCount: maximumCount)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                heatmapContent(layout: layout, maximumCount: maximumCount)
                    .frame(
                        maxWidth: .infinity,
                        alignment: isExpanded ? .center : .leading
                    )
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: isExpanded ? 240 : 180,
            alignment: isExpanded ? .center : .leading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request activity heatmap for \(rangeLabel)")
    }

    private func dailyHeatmapContent(
        layout: HeatmapLayout,
        maximumCount: Int
    ) -> some View {
        let cells = layout.rows.first?.cells ?? []
        let columnCount = isExpanded ? 12 : 6
        let columns = Array(
            repeating: GridItem(.fixed(layout.cellWidth), spacing: layout.spacing),
            count: columnCount
        )

        return LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: isExpanded ? 12 : 9
        ) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                VStack(spacing: 5) {
                    activityCell(
                        cell,
                        width: layout.cellWidth,
                        maximumCount: maximumCount
                    )
                    Text(layout.columnLabels[index])
                        .font(.system(size: isExpanded ? 9 : 7.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: layout.cellWidth)
                }
            }
        }
    }

    private func heatmapContent(
        layout: HeatmapLayout,
        maximumCount: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: layout.spacing) {
                ForEach(layout.rows) { row in
                    Text(row.label)
                        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(
                            width: layout.rowLabelWidth,
                            height: layout.cellWidth,
                            alignment: .trailing
                        )
                }
            }

            VStack(spacing: 7) {
                VStack(spacing: layout.spacing) {
                    ForEach(layout.rows) { row in
                        HStack(spacing: layout.spacing) {
                            ForEach(row.cells) { cell in
                                activityCell(
                                    cell,
                                    width: layout.cellWidth,
                                    maximumCount: maximumCount
                                )
                            }
                        }
                    }
                }

                HStack(spacing: layout.spacing) {
                    ForEach(Array(layout.columnLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: layout.columnLabels.count >= 12 ? 7.5 : 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: layout.cellWidth)
                    }
                }
            }
        }
    }

    private func activityCell(
        _ cell: HeatmapCell,
        width: CGFloat,
        maximumCount: Int
    ) -> some View {
        HoverableHeatmapCell(
            fillColor: heatmapColor(for: cell.count, maximumCount: maximumCount),
            borderColor: cell.count == 0
                ? DashboardPalette.panelStroke.opacity(0.7)
                : Color.white.opacity(0.07),
            width: width,
            help: cell.help
        )
    }

    private var periodBreakdown: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                if totalRequestCount == 0 {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                } else {
                    HStack(spacing: 3) {
                        ForEach(UserActivityPeriod.allCases) { period in
                            Capsule()
                                .fill(period.color)
                                .frame(
                                    width: max(
                                        3,
                                        (geometry.size.width - 6) * periodShare(period)
                                    )
                                )
                        }
                    }
                }
            }
            .frame(height: 6)

            HStack(alignment: .top, spacing: 8) {
                ForEach(UserActivityPeriod.allCases) { period in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(percentLabel(for: period))
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Text(period.title)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var heatmapLayout: HeatmapLayout {
        switch range {
        case .last24Hours:
            dailyHeatmapLayout
        case .last7Days:
            weeklyHeatmapLayout
        case .last30Days:
            monthlyHeatmapLayout
        case .lastYear:
            yearlyHeatmapLayout
        case .allTime:
            allTimeHeatmapLayout
        }
    }

    private var dailyHeatmapLayout: HeatmapLayout {
        let currentHour = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: Date())
        ) ?? Date()
        let hours = (0..<24).compactMap {
            calendar.date(byAdding: .hour, value: $0 - 23, to: currentHour)
        }
        let cells = hours.map { start in
            let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
            let count = requestCount(from: start, to: end)
            return HeatmapCell(
                id: "hour-\(start.timeIntervalSince1970)",
                count: count,
                help: "\(Self.tooltipDateFormatter.string(from: start)), \(hourLabel(calendar.component(.hour, from: start))): \(count) requests"
            )
        }
        let labels = hours.map { hourLabel(calendar.component(.hour, from: $0)) }

        return HeatmapLayout(
            columnLabels: labels,
            rows: [HeatmapRow(id: "hours", label: "", cells: cells)],
            rowLabelWidth: 0,
            cellWidth: isExpanded ? 34 : 32,
            spacing: isExpanded ? 9 : 7
        )
    }

    private var weeklyHeatmapLayout: HeatmapLayout {
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0 - 6, to: today)
        }
        let rows = Self.timeBlocks.map { hour in
            HeatmapRow(
                id: "time-\(hour)",
                label: hourLabel(hour),
                cells: days.map { day in
                    let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
                    let end = calendar.date(byAdding: .hour, value: 4, to: start) ?? start
                    let count = requestCount(from: start, to: end)
                    return HeatmapCell(
                        id: "week-\(day.timeIntervalSince1970)-\(hour)",
                        count: count,
                        help: "\(Self.tooltipDateFormatter.string(from: day)), \(hourLabel(hour))–\(hourLabel((hour + 4) % 24)): \(count) requests"
                    )
                }
            )
        }

        return HeatmapLayout(
            columnLabels: days.map { Self.weekdayFormatter.string(from: $0) },
            rows: rows,
            rowLabelWidth: isExpanded ? 52 : 40,
            cellWidth: isExpanded ? 34 : 25,
            spacing: isExpanded ? 9 : 7
        )
    }

    private var monthlyHeatmapLayout: HeatmapLayout {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let dates = (0..<35).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
        let rows = (0..<5).map { week in
            let weekDates = Array(dates[(week * 7)..<(week * 7 + 7)])
            return HeatmapRow(
                id: "week-\(week)",
                label: "Week \(week + 1)",
                cells: weekDates.map { day in
                    let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                    let isInRange = day <= today
                    let count = isInRange ? requestCount(from: day, to: end) : 0
                    return HeatmapCell(
                        id: "month-\(day.timeIntervalSince1970)",
                        count: count,
                        help: isInRange
                            ? "\(Self.tooltipDateFormatter.string(from: day)): \(count) requests"
                            : "Outside the selected period"
                    )
                }
            )
        }

        return HeatmapLayout(
            columnLabels: Array(dates.prefix(7)).map { Self.weekdayFormatter.string(from: $0) },
            rows: rows,
            rowLabelWidth: isExpanded ? 52 : 40,
            cellWidth: isExpanded ? 34 : 25,
            spacing: isExpanded ? 9 : 7
        )
    }

    private var yearlyHeatmapLayout: HeatmapLayout {
        let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        let months = (0..<12).compactMap {
            calendar.date(byAdding: .month, value: $0 - 11, to: currentMonth)
        }
        let rows = (0..<5).map { week in
            HeatmapRow(
                id: "month-week-\(week)",
                label: "Week \(week + 1)",
                cells: months.map { month in
                    let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) ?? month
                    let start = calendar.date(byAdding: .day, value: week * 7, to: month) ?? month
                    let proposedEnd = calendar.date(byAdding: .day, value: 7, to: start) ?? start
                    let end = min(proposedEnd, nextMonth)
                    let count = start < nextMonth ? requestCount(from: start, to: end) : 0
                    return HeatmapCell(
                        id: "year-\(month.timeIntervalSince1970)-\(week)",
                        count: count,
                        help: "\(Self.monthFormatter.string(from: month)), week \(week + 1): \(count) requests"
                    )
                }
            )
        }

        return HeatmapLayout(
            columnLabels: months.map { Self.shortMonthFormatter.string(from: $0) },
            rows: rows,
            rowLabelWidth: isExpanded ? 52 : 40,
            cellWidth: isExpanded ? 32 : 17,
            spacing: isExpanded ? 8 : 4.5
        )
    }

    private var allTimeHeatmapLayout: HeatmapLayout {
        let pointYears = Array(Set(points.map { calendar.component(.year, from: $0.bucketStart) })).sorted()
        let years = pointYears.isEmpty ? [calendar.component(.year, from: Date())] : pointYears
        let rowYearGroups: [[Int]]
        if years.count <= 6 {
            rowYearGroups = years.map { [$0] }
        } else {
            rowYearGroups = [Array(years.dropLast(5))] + years.suffix(5).map { [$0] }
        }
        let rows = rowYearGroups.map { yearGroup in
            let label = yearGroup.count == 1
                ? String(yearGroup[0])
                : "≤\(yearGroup.last ?? 0)"
            return HeatmapRow(
                id: "years-\(yearGroup.map(String.init).joined(separator: "-"))",
                label: label,
                cells: (1...12).map { month in
                    let count = requestCount(month: month, years: Set(yearGroup))
                    return HeatmapCell(
                        id: "all-\(label)-\(month)",
                        count: count,
                        help: "\(Self.monthNames[month - 1]) \(label): \(count) requests"
                    )
                }
            )
        }

        return HeatmapLayout(
            columnLabels: Self.shortMonthNames,
            rows: rows,
            rowLabelWidth: isExpanded ? 52 : 40,
            cellWidth: isExpanded ? 32 : 17,
            spacing: isExpanded ? 8 : 4.5
        )
    }

    private var totalRequestCount: Int {
        points.reduce(0) { $0 + $1.requestCount }
    }

    private func requestCount(from start: Date, to end: Date) -> Int {
        return points.reduce(0) { result, point in
            guard point.bucketStart >= start, point.bucketStart < end else {
                return result
            }
            return result + point.requestCount
        }
    }

    private func requestCount(month: Int, years: Set<Int>) -> Int {
        points.reduce(0) { result, point in
            let components = calendar.dateComponents([.year, .month], from: point.bucketStart)
            guard components.month == month,
                  components.year.map(years.contains) == true
            else {
                return result
            }
            return result + point.requestCount
        }
    }

    private func heatmapColor(for count: Int, maximumCount: Int) -> Color {
        guard count > 0, maximumCount > 0 else {
            return Color.secondary.opacity(0.08)
        }
        let intensity = Double(count) / Double(max(maximumCount, 4))
        return DashboardPalette.accent.opacity(0.24 + (intensity * 0.76))
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12 am"
        case 1..<12: "\(hour) am"
        case 12: "12 pm"
        default: "\(hour - 12) pm"
        }
    }

    private var rangeLabel: String {
        switch range {
        case .last24Hours: "the past 24 hours"
        case .last7Days: "the past 7 days"
        case .last30Days: "the past 30 days"
        case .lastYear: "the past year"
        case .allTime: "all time"
        }
    }

    private func periodShare(_ period: UserActivityPeriod) -> Double {
        guard totalRequestCount > 0 else { return 0 }
        return Double(requestCount(for: period)) / Double(totalRequestCount)
    }

    private func requestCount(for period: UserActivityPeriod) -> Int {
        points.reduce(0) { result, point in
            let hour = calendar.component(.hour, from: point.bucketStart)
            return period.contains(hour: hour) ? result + point.requestCount : result
        }
    }

    private func percentLabel(for period: UserActivityPeriod) -> String {
        "\(Int((periodShare(period) * 100).rounded()))%"
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let tooltipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return formatter
    }()

    private static let shortMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let monthNames: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.monthSymbols
    }()

    private static let shortMonthNames: [String] = monthNames.map {
        String($0.prefix(3))
    }

}

private struct ActivityLegendItem: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 14, height: 9)
            Text(title)
        }
    }
}

private enum UserActivityPeriod: CaseIterable, Identifiable {
    case morning
    case daytime
    case evening

    var id: Self { self }

    var title: String {
        switch self {
        case .morning: "Morning"
        case .daytime: "Daytime"
        case .evening: "Evening"
        }
    }

    var color: Color {
        switch self {
        case .morning: DashboardPalette.indigo
        case .daytime: DashboardPalette.positive
        case .evening: DashboardPalette.orange
        }
    }

    func contains(hour: Int) -> Bool {
        switch self {
        case .morning:
            (5..<12).contains(hour)
        case .daytime:
            (12..<18).contains(hour)
        case .evening:
            !(5..<18).contains(hour)
        }
    }
}

private enum DashboardOverviewMetric: String {
    case tokens
    case requests
    case successRate
    case decodeSpeed
}

private struct SuccessRateModelSummary: Identifiable {
    let modelID: String
    let requestsCompleted: Int
    let requestsFailed: Int

    var id: String { modelID }

    var totalRequests: Int {
        requestsCompleted + requestsFailed
    }

    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(requestsCompleted) / Double(totalRequests)
    }

    var logRequestCount: Double {
        log10(Double(totalRequests) + 1)
    }
}

private struct TokenUsagePanel: View {
    struct HistogramSegment: Identifiable {
        let modelID: String
        let bucketStart: Date
        let yStart: Int
        let yEnd: Int

        var id: String { "\(modelID):\(bucketStart.timeIntervalSince1970)" }
    }

    struct RequestHistogramSegment: Identifiable {
        let bucketStart: Date
        let status: String
        let yStart: Int
        let yEnd: Int
        let color: Color

        var id: String { "\(status):\(bucketStart.timeIntervalSince1970)" }
    }

    struct ModelRequestHistogramSegment: Identifiable {
        let modelID: String
        let bucketStart: Date
        let yStart: Int
        let yEnd: Int

        var id: String { "\(modelID):\(bucketStart.timeIntervalSince1970)" }
    }

    enum AllModelsDisplay: String, CaseIterable, Identifiable {
        case lines = "Lines"
        case stacked = "Histogram"

        var id: String { rawValue }
    }

    let metric: DashboardOverviewMetric
    let points: [DashboardViewModel.BucketPoint]
    let modelPoints: [DashboardViewModel.ModelTokenPoint]
    let range: DashboardViewModel.RangeOption
    let showsAllModels: Bool
    @State private var hoveredPointID: Date?
    @State private var allModelsDisplay: AllModelsDisplay = .lines

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                AnalyticsSectionHeader(
                    title: chartTitle,
                    subtitle: chartSubtitle
                )
                Spacer()
                if metric == .tokens && showsAllModels {
                    Picker("Chart display", selection: $allModelsDisplay) {
                        ForEach(AllModelsDisplay.allCases) { display in
                            Text(display.rawValue).tag(display)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                } else if !showsAllModels || metric == .requests {
                    chartLegend
                }
            }

            if points.isEmpty {
                DashboardEmptyChart()
                    .frame(minHeight: 230)
            } else if usesSuccessRateComparison {
                SuccessRateModelComparisonChart(summaries: modelSuccessSummaries)
            } else {
                Chart {
                    usageMarks
                    hoverMarks
                }
                .chartLegend(showsAllModels ? .visible : .hidden)
                .chartForegroundStyleScale(
                    domain: modelColorDomain,
                    range: DashboardModelColorScale.colors(for: modelColorDomain)
                )
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                        AxisTick().foregroundStyle(DashboardPalette.axisTick)
                        if let date = value.as(Date.self) {
                            AxisValueLabel(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisText)
                        }
                    }
                }
                .chartYAxis {
                    if metric == .successRate {
                        AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                            AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                            AxisTick().foregroundStyle(DashboardPalette.axisTick)
                            if let raw = value.as(Double.self) {
                                AxisValueLabel(yAxisLabel(for: raw))
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.axisText)
                            }
                        }
                    } else {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                            AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                            AxisTick().foregroundStyle(DashboardPalette.axisTick)
                            if let raw = value.as(Double.self) {
                                AxisValueLabel(yAxisLabel(for: raw))
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.axisText)
                            }
                        }
                        if metric == .requests && hasTTFTData {
                            AxisMarks(position: .trailing, values: ttftAxisPlotValues) { value in
                                AxisTick().foregroundStyle(DashboardPalette.latency.opacity(0.7))
                                if let raw = value.as(Double.self) {
                                    AxisValueLabel(
                                        NativFormatting.milliseconds(
                                            ttftMilliseconds(forPlotValue: raw)
                                        )
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.latency)
                                }
                            }
                        }
                    }
                }
                .chartYScale(domain: yDomain)
                .frame(height: 250)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateHoveredPoint(
                                            at: location,
                                            proxy: proxy,
                                            geometry: geometry
                                        )
                                    case .ended:
                                        hoveredPointID = nil
                                    }
                                }

                            if let hoveredPoint,
                               let tooltipCenter = tooltipCenter(
                                   for: hoveredPoint,
                                   proxy: proxy,
                                   geometry: geometry
                               ) {
                                Group {
                                    if metric == .tokens && showsAllModels {
                                        ModelTokenUsageTooltip(
                                            date: hoveredPoint.bucketStart,
                                            points: modelValues(at: hoveredPoint.bucketStart),
                                            modelColorDomain: modelColorDomain,
                                            granularity: granularity
                                        )
                                    } else if showsAllModels {
                                        ModelOverviewTooltip(
                                            metric: metric,
                                            date: hoveredPoint.bucketStart,
                                            points: tooltipModelValues(at: hoveredPoint.bucketStart),
                                            modelColorDomain: modelColorDomain,
                                            ttftMilliseconds: metric == .requests
                                                ? hoveredPoint.averageTTFTMilliseconds
                                                : nil,
                                            granularity: granularity
                                        )
                                    } else if metric == .tokens {
                                        TokenUsageTooltip(point: hoveredPoint, granularity: granularity)
                                    } else {
                                        DashboardMetricTooltip(
                                            metric: metric,
                                            point: hoveredPoint,
                                            granularity: granularity
                                        )
                                    }
                                }
                                .position(tooltipCenter)
                                .allowsHitTesting(false)
                                .transition(.identity)
                            }
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                }
                .onChange(of: points) { _, newPoints in
                    if let hoveredPointID,
                       !newPoints.contains(where: { $0.id == hoveredPointID }) {
                        self.hoveredPointID = nil
                    }
                }
                .onChange(of: metric) { _, _ in
                    hoveredPointID = nil
                }
                .animation(.easeInOut(duration: 0.2), value: metric)
            }
        }
        .padding(18)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var chartTitle: String {
        switch metric {
        case .tokens:
            "Token usage"
        case .requests:
            "Requests"
        case .successRate:
            "Success rate"
        case .decodeSpeed:
            "Decode speed"
        }
    }

    private var chartSubtitle: String {
        switch metric {
        case .tokens:
            showsAllModels ? "Total tokens by model over time" : "Input and output tokens over time"
        case .requests:
            showsAllModels
                ? "Request volume by model with average TTFT"
                : "Completed, failed, and average TTFT over time"
        case .successRate:
            if showsAllModels && modelSuccessSummaries.count > 50 {
                "Reliability versus request volume across models"
            } else if showsAllModels && modelSuccessSummaries.count >= 10 {
                "Models ranked by reliability · worst first"
            } else if showsAllModels {
                "Successful requests by model over time"
            } else {
                "Successful requests over time"
            }
        case .decodeSpeed:
            showsAllModels
                ? "Decode speed by model over time"
                : "Generated tokens per second over time"
        }
    }

    @ViewBuilder
    private var chartLegend: some View {
        HStack(spacing: 14) {
            switch metric {
            case .tokens:
                ChartLegendDot(color: DashboardPalette.accent, title: "Input")
                ChartLegendDot(color: DashboardPalette.indigo, title: "Output")
            case .requests:
                if !showsAllModels {
                    ChartLegendDot(color: DashboardPalette.positive, title: "Completed")
                    ChartLegendDot(color: DashboardPalette.negative, title: "Failed")
                }
                ChartLegendDot(color: DashboardPalette.latency, title: "TTFT (ms)")
            case .successRate:
                ChartLegendDot(color: DashboardPalette.positive, title: "Success rate")
                ChartLegendDot(color: DashboardPalette.orange, title: "95% target")
            case .decodeSpeed:
                ChartLegendDot(color: DashboardPalette.orange, title: "Tokens/s")
            }
        }
    }

    @ChartContentBuilder
    private var usageMarks: some ChartContent {
        switch metric {
        case .tokens:
            if showsAllModels {
                allModelMarks
            } else {
                inputOutputMarks
            }
        case .requests:
            if showsAllModels {
                allModelRequestMarks
            } else {
                requestMarks
            }
            ttftMarks
        case .successRate:
            if showsAllModels {
                allModelSuccessRateMarks
            } else {
                successRateMarks
            }
        case .decodeSpeed:
            if showsAllModels {
                allModelDecodeSpeedMarks
            } else {
                decodeSpeedMarks
            }
        }
    }

    @ChartContentBuilder
    private var allModelMarks: some ChartContent {
        if allModelsDisplay == .lines {
            ForEach(modelPoints) { point in
                LineMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Total tokens", Double(point.totalTokens)),
                    series: .value("Model", point.modelID)
                )
                .foregroundStyle(by: .value("Model", point.modelID))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
        } else {
            ForEach(histogramSegments) { segment in
                RectangleMark(
                    xStart: .value("Bucket start", segment.bucketStart),
                    xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                    yStart: .value("Token start", Double(segment.yStart)),
                    yEnd: .value("Token end", Double(segment.yEnd))
                )
                .foregroundStyle(by: .value("Model", segment.modelID))
                .opacity(0.9)
            }
        }
    }

    @ChartContentBuilder
    private var inputOutputMarks: some ChartContent {
        ForEach(points) { point in
            AreaMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Baseline", 0.0),
                yEnd: .value("Input tokens", Double(point.promptTokensTotal))
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [DashboardPalette.accent.opacity(0.28), DashboardPalette.accent.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Input tokens", Double(point.promptTokensTotal)),
                series: .value("Series", "Input")
            )
            .foregroundStyle(DashboardPalette.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Output tokens", Double(point.generatedTokensTotal)),
                series: .value("Series", "Output")
            )
            .foregroundStyle(DashboardPalette.indigo)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var requestMarks: some ChartContent {
        ForEach(requestHistogramSegments) { segment in
            RectangleMark(
                xStart: .value("Bucket start", segment.bucketStart),
                xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                yStart: .value("Request start", Double(segment.yStart)),
                yEnd: .value("Request end", Double(segment.yEnd))
            )
            .foregroundStyle(segment.color.gradient)
            .opacity(
                hoveredPointID == nil || hoveredPointID == segment.bucketStart
                    ? 0.92
                    : 0.35
            )
        }
    }

    @ChartContentBuilder
    private var allModelRequestMarks: some ChartContent {
        ForEach(modelRequestHistogramSegments) { segment in
            RectangleMark(
                xStart: .value("Bucket start", segment.bucketStart),
                xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                yStart: .value("Request start", Double(segment.yStart)),
                yEnd: .value("Request end", Double(segment.yEnd))
            )
            .foregroundStyle(by: .value("Model", segment.modelID))
            .opacity(
                hoveredPointID == nil || hoveredPointID == segment.bucketStart
                    ? 0.92
                    : 0.35
            )
        }
    }

    @ChartContentBuilder
    private var ttftMarks: some ChartContent {
        ForEach(points) { point in
            if let ttft = point.averageTTFTMilliseconds {
                LineMark(
                    x: .value("Time", hoverDate(for: point)),
                    y: .value("TTFT", scaledTTFT(ttft))
                )
                .foregroundStyle(DashboardPalette.latency)
                .lineStyle(StrokeStyle(lineWidth: 2.2))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Time", hoverDate(for: point)),
                    y: .value("TTFT", scaledTTFT(ttft))
                )
                .foregroundStyle(DashboardPalette.latency)
                .symbolSize(20)
            }
        }
    }

    @ChartContentBuilder
    private var successRateMarks: some ChartContent {
        RuleMark(y: .value("Reliability target", 0.95))
            .foregroundStyle(DashboardPalette.orange.opacity(0.78))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

        ForEach(successRatePoints) { point in
            let successRate = successRate(for: point) ?? 0
            AreaMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Baseline", 0.0),
                yEnd: .value("Success rate", successRate)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [DashboardPalette.positive.opacity(0.24), DashboardPalette.positive.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Success rate", successRate)
            )
            .foregroundStyle(DashboardPalette.positive)
            .lineStyle(StrokeStyle(lineWidth: 2.2))
            .interpolationMethod(.monotone)

            PointMark(
                x: .value("Time", point.bucketStart),
                y: .value("Success rate", successRate)
            )
            .foregroundStyle(successRateColor(for: successRate))
            .symbolSize(28)
        }
    }

    @ChartContentBuilder
    private var allModelSuccessRateMarks: some ChartContent {
        RuleMark(y: .value("Reliability target", 0.95))
            .foregroundStyle(DashboardPalette.orange.opacity(0.78))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

        ForEach(modelSuccessRatePoints) { point in
            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Success rate", point.successRate ?? 0),
                series: .value("Model", point.modelID)
            )
            .foregroundStyle(by: .value("Model", point.modelID))
            .lineStyle(StrokeStyle(lineWidth: 2.2))
            .interpolationMethod(.monotone)

            PointMark(
                x: .value("Time", point.bucketStart),
                y: .value("Success rate", point.successRate ?? 0)
            )
            .foregroundStyle(by: .value("Model", point.modelID))
            .opacity(
                hoveredPointID == nil || hoveredPointID == point.bucketStart
                    ? 0.9
                    : 0.3
            )
            .symbolSize(28)
        }
    }

    @ChartContentBuilder
    private var decodeSpeedMarks: some ChartContent {
        ForEach(points) { point in
            if let decodeSpeed = decodeSpeed(for: point) {
                AreaMark(
                    x: .value("Time", point.bucketStart),
                    yStart: .value("Baseline", 0.0),
                    yEnd: .value("Decode speed", decodeSpeed)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [DashboardPalette.orange.opacity(0.25), DashboardPalette.orange.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Decode speed", decodeSpeed)
                )
                .foregroundStyle(DashboardPalette.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
        }
    }

    @ChartContentBuilder
    private var allModelDecodeSpeedMarks: some ChartContent {
        ForEach(modelPoints) { point in
            if let decodeSpeed = point.decodeSpeed {
                LineMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Decode speed", decodeSpeed),
                    series: .value("Model", point.modelID)
                )
                .foregroundStyle(by: .value("Model", point.modelID))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
        }
    }

    @ChartContentBuilder
    private var hoverMarks: some ChartContent {
        if let hoveredPoint {
            RuleMark(x: .value("Selected time", hoverDate(for: hoveredPoint)))
                .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            switch metric {
            case .tokens:
                if showsAllModels {
                    ForEach(modelValues(at: hoveredPoint.bucketStart)) { modelPoint in
                        PointMark(
                            x: .value("Selected time", modelPoint.bucketStart),
                            y: .value("Total tokens", Double(modelPoint.totalTokens))
                        )
                        .foregroundStyle(by: .value("Model", modelPoint.modelID))
                        .symbolSize(42)
                    }
                } else {
                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Input tokens", Double(hoveredPoint.promptTokensTotal))
                    )
                    .foregroundStyle(DashboardPalette.accent)
                    .symbolSize(48)

                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Output tokens", Double(hoveredPoint.generatedTokensTotal))
                    )
                    .foregroundStyle(DashboardPalette.indigo)
                    .symbolSize(48)
                }
            case .requests:
                if showsAllModels {
                    ForEach(modelRequestSegments(at: hoveredPoint.bucketStart)) { segment in
                        PointMark(
                            x: .value("Selected time", hoverDate(for: hoveredPoint)),
                            y: .value("Requests", Double(segment.yEnd))
                        )
                        .foregroundStyle(by: .value("Model", segment.modelID))
                        .symbolSize(48)
                    }
                } else {
                    if hoveredPoint.requestsCompleted > 0 {
                        PointMark(
                            x: .value("Selected time", hoverDate(for: hoveredPoint)),
                            y: .value("Completed", Double(hoveredPoint.requestsCompleted))
                        )
                        .foregroundStyle(DashboardPalette.positive)
                        .symbolSize(48)
                    }

                    if hoveredPoint.requestsFailed > 0 {
                        PointMark(
                            x: .value("Selected time", hoverDate(for: hoveredPoint)),
                            y: .value(
                                "Total requests",
                                Double(hoveredPoint.requestsCompleted + hoveredPoint.requestsFailed)
                            )
                        )
                        .foregroundStyle(DashboardPalette.negative)
                        .symbolSize(48)
                    }
                }
                if let ttft = hoveredPoint.averageTTFTMilliseconds {
                    PointMark(
                        x: .value("Selected time", hoverDate(for: hoveredPoint)),
                        y: .value("TTFT", scaledTTFT(ttft))
                    )
                    .foregroundStyle(DashboardPalette.latency)
                    .symbolSize(58)
                }
            case .successRate:
                if showsAllModels {
                    ForEach(successModelValues(at: hoveredPoint.bucketStart)) { modelPoint in
                        PointMark(
                            x: .value("Selected time", modelPoint.bucketStart),
                            y: .value("Success rate", modelPoint.successRate ?? 0)
                        )
                        .foregroundStyle(by: .value("Model", modelPoint.modelID))
                        .symbolSize(54)
                    }
                } else {
                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Success rate", successRate(for: hoveredPoint) ?? 0)
                    )
                    .foregroundStyle(successRateColor(for: successRate(for: hoveredPoint) ?? 0))
                    .symbolSize(54)
                }
            case .decodeSpeed:
                if showsAllModels {
                    ForEach(modelValues(at: hoveredPoint.bucketStart)) { modelPoint in
                        if let decodeSpeed = modelPoint.decodeSpeed {
                            PointMark(
                                x: .value("Selected time", modelPoint.bucketStart),
                                y: .value("Decode speed", decodeSpeed)
                            )
                            .foregroundStyle(by: .value("Model", modelPoint.modelID))
                            .symbolSize(48)
                        }
                    }
                } else if let decodeSpeed = decodeSpeed(for: hoveredPoint) {
                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Decode speed", decodeSpeed)
                    )
                    .foregroundStyle(DashboardPalette.orange)
                    .symbolSize(48)
                }
            }
        }
    }

    private var hoveredPoint: DashboardViewModel.BucketPoint? {
        guard let hoveredPointID else { return nil }
        return points.first { $0.id == hoveredPointID }
    }

    private var granularity: NativAnalyticsGranularity {
        points.first?.granularity ?? (range == .last24Hours ? .hour : .day)
    }

    private var axisDates: [Date] {
        DashboardChartAxis.markDates(from: points.map(\.bucketStart), maximumCount: 6)
    }

    private var modelColorDomain: [String] {
        DashboardModelColorScale.domain(for: modelPoints.map(\.modelID))
    }

    private var successRatePoints: [DashboardViewModel.BucketPoint] {
        points.filter { $0.requestsCompleted + $0.requestsFailed > 0 }
    }

    private var modelSuccessRatePoints: [DashboardViewModel.ModelTokenPoint] {
        modelPoints.filter { $0.totalRequests > 0 }
    }

    private var modelSuccessSummaries: [SuccessRateModelSummary] {
        Dictionary(grouping: modelSuccessRatePoints, by: \.modelID)
            .map { modelID, points in
                SuccessRateModelSummary(
                    modelID: modelID,
                    requestsCompleted: points.reduce(0) { $0 + $1.requestsCompleted },
                    requestsFailed: points.reduce(0) { $0 + $1.requestsFailed }
                )
            }
            .filter { $0.totalRequests > 0 }
            .sorted {
                if $0.successRate == $1.successRate {
                    return $0.totalRequests > $1.totalRequests
                }
                return $0.successRate < $1.successRate
            }
    }

    private var usesSuccessRateComparison: Bool {
        metric == .successRate && showsAllModels && modelSuccessSummaries.count >= 10
    }

    private var yDomain: ClosedRange<Double> {
        if metric == .successRate {
            return 0...1
        }

        let maximum: Double
        switch metric {
        case .tokens where showsAllModels && allModelsDisplay == .stacked:
            maximum = Dictionary(grouping: modelPoints, by: \.bucketStart)
                .values
                .map { points in Double(points.reduce(0) { $0 + $1.totalTokens }) }
                .max() ?? 0
        case .tokens where showsAllModels:
            maximum = Double(modelPoints.map(\.totalTokens).max() ?? 0)
        case .tokens:
            maximum = Double(points.map { max($0.promptTokensTotal, $0.generatedTokensTotal) }.max() ?? 0)
        case .requests:
            maximum = Double(
                points.map { $0.requestsCompleted + $0.requestsFailed }.max() ?? 0
            )
        case .successRate:
            maximum = 1
        case .decodeSpeed:
            maximum = showsAllModels
                ? modelPoints.compactMap(\.decodeSpeed).max() ?? 0
                : points.compactMap(decodeSpeed(for:)).max() ?? 0
        }

        return 0...max(maximum * 1.1, 1)
    }

    private var hasTTFTData: Bool {
        points.contains { $0.averageTTFTMilliseconds != nil }
    }

    private var ttftAxisMaximum: Double {
        max((points.compactMap(\.averageTTFTMilliseconds).max() ?? 0) * 1.1, 1)
    }

    private var ttftAxisPlotValues: [Double] {
        let maximum = yDomain.upperBound
        return [0, maximum / 2, maximum]
    }

    private func scaledTTFT(_ milliseconds: Double) -> Double {
        milliseconds / ttftAxisMaximum * yDomain.upperBound
    }

    private func ttftMilliseconds(forPlotValue value: Double) -> Double {
        value / yDomain.upperBound * ttftAxisMaximum
    }

    private func yAxisLabel(for value: Double) -> String {
        switch metric {
        case .tokens, .requests:
            NativFormatting.compactCount(Int(value.rounded())).display
        case .successRate:
            NativFormatting.percent(value)
        case .decodeSpeed:
            value == 0 ? "0 tok/s" : NativFormatting.rate(value)
        }
    }

    private func successRate(for point: DashboardViewModel.BucketPoint) -> Double? {
        let total = point.requestsCompleted + point.requestsFailed
        guard total > 0 else { return nil }
        return Double(point.requestsCompleted) / Double(total)
    }

    private func successRateColor(for value: Double) -> Color {
        if value >= 0.95 {
            DashboardPalette.positive
        } else if value >= 0.8 {
            DashboardPalette.orange
        } else {
            DashboardPalette.negative
        }
    }

    private func decodeSpeed(for point: DashboardViewModel.BucketPoint) -> Double? {
        guard point.decodeTokensTotal > 0, point.decodeTimeTotalMilliseconds > 0 else {
            return nil
        }
        return Double(point.decodeTokensTotal) / (Double(point.decodeTimeTotalMilliseconds) / 1_000)
    }

    private func modelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        modelPoints
            .filter { $0.bucketStart == date }
            .sorted { modelValue(for: $0) > modelValue(for: $1) }
    }

    private func successModelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        modelValues(at: date).filter { $0.totalRequests > 0 }
    }

    private func modelValue(for point: DashboardViewModel.ModelTokenPoint) -> Double {
        switch metric {
        case .tokens:
            Double(point.totalTokens)
        case .requests:
            Double(point.totalRequests)
        case .successRate:
            point.successRate ?? 0
        case .decodeSpeed:
            point.decodeSpeed ?? 0
        }
    }

    private var histogramSegments: [HistogramSegment] {
        Dictionary(grouping: modelPoints, by: \.bucketStart)
            .flatMap { bucketStart, bucketPoints in
                var cumulative = 0
                return bucketPoints
                    .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                    .map { point in
                        let segment = HistogramSegment(
                            modelID: point.modelID,
                            bucketStart: bucketStart,
                            yStart: cumulative,
                            yEnd: cumulative + point.totalTokens
                        )
                        cumulative += point.totalTokens
                        return segment
                    }
            }
            .sorted {
                if $0.bucketStart == $1.bucketStart { return $0.yStart < $1.yStart }
                return $0.bucketStart < $1.bucketStart
            }
    }

    private var requestHistogramSegments: [RequestHistogramSegment] {
        points.flatMap { point in
            var segments: [RequestHistogramSegment] = []
            if point.requestsCompleted > 0 {
                segments.append(
                    RequestHistogramSegment(
                        bucketStart: point.bucketStart,
                        status: "Completed",
                        yStart: 0,
                        yEnd: point.requestsCompleted,
                        color: DashboardPalette.positive
                    )
                )
            }
            if point.requestsFailed > 0 {
                segments.append(
                    RequestHistogramSegment(
                        bucketStart: point.bucketStart,
                        status: "Failed",
                        yStart: point.requestsCompleted,
                        yEnd: point.requestsCompleted + point.requestsFailed,
                        color: DashboardPalette.negative
                    )
                )
            }
            return segments
        }
    }

    private var modelRequestHistogramSegments: [ModelRequestHistogramSegment] {
        Dictionary(grouping: modelPoints, by: \.bucketStart)
            .flatMap { bucketStart, bucketPoints in
                var cumulative = 0
                return bucketPoints
                    .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                    .compactMap { point -> ModelRequestHistogramSegment? in
                        guard point.totalRequests > 0 else { return nil }
                        let segment = ModelRequestHistogramSegment(
                            modelID: point.modelID,
                            bucketStart: bucketStart,
                            yStart: cumulative,
                            yEnd: cumulative + point.totalRequests
                        )
                        cumulative += point.totalRequests
                        return segment
                    }
            }
            .sorted {
                if $0.bucketStart == $1.bucketStart { return $0.yStart < $1.yStart }
                return $0.bucketStart < $1.bucketStart
            }
    }

    private func modelRequestSegments(at date: Date) -> [ModelRequestHistogramSegment] {
        modelRequestHistogramSegments.filter { $0.bucketStart == date }
    }

    private func bucketEnd(after date: Date) -> Date {
        switch granularity {
        case .hour:
            Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        case .day:
            Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
    }

    private func axisLabel(for date: Date) -> String {
        DashboardChartAxis.label(
            for: date,
            granularity: granularity,
            range: range
        )
    }

    private func updateHoveredPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredPointID = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredPointID = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        guard let hoveredDate: Date = proxy.value(atX: plotX) else {
            hoveredPointID = nil
            return
        }

        let nextPoint: DashboardViewModel.BucketPoint?
        if metric == .requests {
            nextPoint = points.first {
                hoveredDate >= $0.bucketStart && hoveredDate < bucketEnd(after: $0.bucketStart)
            }
        } else if metric == .successRate {
            nextPoint = successRatePoints.min {
                abs($0.bucketStart.timeIntervalSince(hoveredDate))
                    < abs($1.bucketStart.timeIntervalSince(hoveredDate))
            }
        } else {
            nextPoint = points.min {
                abs($0.bucketStart.timeIntervalSince(hoveredDate))
                    < abs($1.bucketStart.timeIntervalSince(hoveredDate))
            }
        }
        guard hoveredPointID != nextPoint?.id else { return }
        hoveredPointID = nextPoint?.id
    }

    private func tooltipCenter(
        for point: DashboardViewModel.BucketPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotX = proxy.position(forX: hoverDate(for: point)),
              let plotY = proxy.position(forY: tooltipAnchorValue(for: point)) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(
            width: showsAllModels ? 230 : 210,
            height: showsAllModels
                ? min(
                    CGFloat(tooltipModelValues(at: point.bucketStart).count) * 25
                        + 72
                        + (metric == .requests && point.averageTTFTMilliseconds != nil ? 32 : 0),
                    304
                )
                : singleMetricTooltipHeight
        )
        let spacing: CGFloat = 12
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - spacing - tooltipSize.width / 2
            : anchor.x + spacing + tooltipSize.width / 2
        let desiredY = anchor.y - spacing - tooltipSize.height / 2

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(desiredY, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }

    private func hoverDate(for point: DashboardViewModel.BucketPoint) -> Date {
        guard metric == .requests else { return point.bucketStart }
        let end = bucketEnd(after: point.bucketStart)
        return point.bucketStart.addingTimeInterval(end.timeIntervalSince(point.bucketStart) / 2)
    }

    private func tooltipModelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        metric == .successRate ? successModelValues(at: date) : modelValues(at: date)
    }

    private var singleMetricTooltipHeight: CGFloat {
        switch metric {
        case .tokens:
            142
        case .requests:
            137
        case .successRate:
            137
        case .decodeSpeed:
            112
        }
    }

    private func tooltipAnchorValue(for point: DashboardViewModel.BucketPoint) -> Double {
        switch metric {
        case .tokens where showsAllModels:
            let values = modelValues(at: point.bucketStart).map(\.totalTokens)
            if allModelsDisplay == .stacked {
                return Double(values.reduce(0, +))
            }
            return Double(values.max() ?? 0)
        case .tokens:
            return Double(max(point.promptTokensTotal, point.generatedTokensTotal))
        case .requests:
            return max(
                Double(point.requestsCompleted + point.requestsFailed),
                point.averageTTFTMilliseconds.map(scaledTTFT) ?? 0
            )
        case .successRate:
            if showsAllModels {
                return successModelValues(at: point.bucketStart).compactMap(\.successRate).max() ?? 0
            }
            return successRate(for: point) ?? 0
        case .decodeSpeed:
            if showsAllModels {
                return modelValues(at: point.bucketStart).compactMap(\.decodeSpeed).max() ?? 0
            }
            return decodeSpeed(for: point) ?? 0
        }
    }
}

private struct SuccessRateModelComparisonChart: View {
    private enum Mode {
        case ranked
        case scatter
    }

    let summaries: [SuccessRateModelSummary]
    @State private var hoveredModelID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            comparisonLegend

            if mode == .ranked {
                rankedChart
            } else {
                scatterChart
            }
        }
        .frame(height: 250, alignment: .top)
        .onChange(of: summaries.map(\.modelID)) { _, modelIDs in
            if let hoveredModelID, !modelIDs.contains(hoveredModelID) {
                self.hoveredModelID = nil
            }
        }
    }

    private var comparisonLegend: some View {
        HStack(spacing: 14) {
            ChartLegendDot(color: DashboardPalette.positive, title: "≥95%")
            ChartLegendDot(color: DashboardPalette.orange, title: "80–95%")
            ChartLegendDot(color: DashboardPalette.negative, title: "<80%")
            Spacer(minLength: 8)
            Text("\(summaries.count) models · \(mode == .ranked ? "ranked" : "by volume")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var rankedChart: some View {
        ScrollView(.vertical) {
            Chart {
                RuleMark(x: .value("Reliability target", 0.95))
                    .foregroundStyle(DashboardPalette.orange.opacity(0.78))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

                ForEach(summaries) { summary in
                    BarMark(
                        x: .value("Success rate", summary.successRate),
                        y: .value("Model", summary.modelID),
                        height: .fixed(3)
                    )
                    .foregroundStyle(healthColor(for: summary.successRate).opacity(0.32))
                    .cornerRadius(2)

                    PointMark(
                        x: .value("Success rate", summary.successRate),
                        y: .value("Model", summary.modelID)
                    )
                    .foregroundStyle(healthColor(for: summary.successRate))
                    .symbolSize(hoveredModelID == summary.modelID ? 72 : 38)
                }
            }
            .chartXScale(domain: 0...1)
            .chartYScale(domain: Array(summaries.map(\.modelID).reversed()))
            .chartXAxis {
                AxisMarks(values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                    AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                    AxisTick().foregroundStyle(DashboardPalette.axisTick)
                    if let raw = value.as(Double.self) {
                        AxisValueLabel(NativFormatting.percent(raw))
                            .font(.caption2)
                            .foregroundStyle(DashboardPalette.axisText)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(DashboardPalette.axisGrid.opacity(0.45))
                    if let modelID = value.as(String.self) {
                        AxisValueLabel(abbreviatedModelID(modelID))
                            .font(.caption2)
                            .foregroundStyle(DashboardPalette.axisText)
                    }
                }
            }
            .frame(height: max(218, CGFloat(summaries.count) * 22))
            .chartOverlay { proxy in
                comparisonOverlay(proxy: proxy, mode: .ranked)
            }
        }
        .frame(height: 218)
        .scrollIndicators(.visible)
    }

    private var scatterChart: some View {
        Chart {
            RuleMark(y: .value("Reliability target", 0.95))
                .foregroundStyle(DashboardPalette.orange.opacity(0.78))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

            ForEach(summaries) { summary in
                PointMark(
                    x: .value("Request volume", summary.logRequestCount),
                    y: .value("Success rate", summary.successRate)
                )
                .foregroundStyle(healthColor(for: summary.successRate))
                .opacity(hoveredModelID == nil || hoveredModelID == summary.modelID ? 0.9 : 0.32)
                .symbolSize(hoveredModelID == summary.modelID ? 86 : 42)
            }
        }
        .chartXScale(domain: 0...max(maximumLogRequestCount * 1.05, 1))
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                AxisTick().foregroundStyle(DashboardPalette.axisTick)
                if let raw = value.as(Double.self) {
                    AxisValueLabel(requestVolumeLabel(for: raw))
                        .font(.caption2)
                        .foregroundStyle(DashboardPalette.axisText)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                AxisTick().foregroundStyle(DashboardPalette.axisTick)
                if let raw = value.as(Double.self) {
                    AxisValueLabel(NativFormatting.percent(raw))
                        .font(.caption2)
                        .foregroundStyle(DashboardPalette.axisText)
                }
            }
        }
        .chartXAxisLabel("Requests · log scale", alignment: .center)
        .frame(height: 218)
        .chartOverlay { proxy in
            comparisonOverlay(proxy: proxy, mode: .scatter)
        }
    }

    private var mode: Mode {
        summaries.count <= 50 ? .ranked : .scatter
    }

    private var hoveredSummary: SuccessRateModelSummary? {
        guard let hoveredModelID else { return nil }
        return summaries.first { $0.modelID == hoveredModelID }
    }

    private var maximumLogRequestCount: Double {
        summaries.map(\.logRequestCount).max() ?? 1
    }

    private func comparisonOverlay(proxy: ChartProxy, mode: Mode) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHoveredModel(
                                at: location,
                                proxy: proxy,
                                geometry: geometry,
                                mode: mode
                            )
                        case .ended:
                            hoveredModelID = nil
                        }
                    }

                if let hoveredSummary,
                   let position = tooltipPosition(
                       for: hoveredSummary,
                       proxy: proxy,
                       geometry: geometry,
                       mode: mode
                   ) {
                    SuccessRateModelSummaryTooltip(summary: hoveredSummary)
                        .position(position)
                        .allowsHitTesting(false)
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private func updateHoveredModel(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        mode: Mode
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredModelID = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredModelID = nil
            return
        }

        let plotLocation = CGPoint(
            x: location.x - plotFrame.minX,
            y: location.y - plotFrame.minY
        )
        let nearest = summaries.compactMap { summary -> (SuccessRateModelSummary, CGFloat)? in
            guard let point = plotPosition(for: summary, proxy: proxy, mode: mode) else {
                return nil
            }
            let distance = hypot(point.x - plotLocation.x, point.y - plotLocation.y)
            return (summary, distance)
        }.min { $0.1 < $1.1 }

        let threshold: CGFloat = mode == .ranked ? 18 : 26
        let nextModelID = nearest.map { $0.1 <= threshold ? $0.0.modelID : nil } ?? nil
        guard nextModelID != hoveredModelID else { return }
        hoveredModelID = nextModelID
    }

    private func tooltipPosition(
        for summary: SuccessRateModelSummary,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        mode: Mode
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotPoint = plotPosition(for: summary, proxy: proxy, mode: mode) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(
            x: plotFrame.minX + plotPoint.x,
            y: plotFrame.minY + plotPoint.y
        )
        let tooltipSize = CGSize(width: 220, height: 92)
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - tooltipSize.width / 2 - 12
            : anchor.x + tooltipSize.width / 2 + 12

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(anchor.y, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }

    private func plotPosition(
        for summary: SuccessRateModelSummary,
        proxy: ChartProxy,
        mode: Mode
    ) -> CGPoint? {
        switch mode {
        case .ranked:
            guard let x = proxy.position(forX: summary.successRate),
                  let y = proxy.position(forY: summary.modelID) else {
                return nil
            }
            return CGPoint(x: x, y: y)
        case .scatter:
            guard let x = proxy.position(forX: summary.logRequestCount),
                  let y = proxy.position(forY: summary.successRate) else {
                return nil
            }
            return CGPoint(x: x, y: y)
        }
    }

    private func healthColor(for value: Double) -> Color {
        if value >= 0.95 {
            DashboardPalette.positive
        } else if value >= 0.8 {
            DashboardPalette.orange
        } else {
            DashboardPalette.negative
        }
    }

    private func abbreviatedModelID(_ modelID: String) -> String {
        guard modelID.count > 24 else { return modelID }
        return "\(modelID.prefix(11))…\(modelID.suffix(10))"
    }

    private func requestVolumeLabel(for logarithmicValue: Double) -> String {
        let requests = max(0, Int((pow(10, logarithmicValue) - 1).rounded()))
        return NativFormatting.compactCount(requests).display
    }
}

private struct SuccessRateModelSummaryTooltip: View {
    let summary: SuccessRateModelSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.modelID)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 14) {
                metric("Success", NativFormatting.percent(summary.successRate))
                metric("Requests", NativFormatting.integer(summary.totalRequests))
                metric("Failed", NativFormatting.integer(summary.requestsFailed))
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.7)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SuccessRateHealthChart: View {
    struct Segment: Identifiable {
        let lane: String
        let bucketStart: Date
        let requestsCompleted: Int
        let requestsFailed: Int

        var id: String { "\(lane):\(bucketStart.timeIntervalSince1970)" }

        var totalRequests: Int {
            requestsCompleted + requestsFailed
        }

        var successRate: Double? {
            guard totalRequests > 0 else { return nil }
            return Double(requestsCompleted) / Double(totalRequests)
        }
    }

    let points: [DashboardViewModel.BucketPoint]
    let modelPoints: [DashboardViewModel.ModelTokenPoint]
    let range: DashboardViewModel.RangeOption
    let showsAllModels: Bool
    @State private var hoveredSegmentID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(overallRateLabel)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                Text(healthStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(segments) { segment in
                    BarMark(
                        xStart: .value("Bucket start", segment.bucketStart),
                        xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                        y: .value("Health lane", segment.lane),
                        height: .ratio(0.72)
                    )
                    .foregroundStyle(color(for: segment).gradient)
                    .opacity(
                        hoveredSegmentID == nil || hoveredSegmentID == segment.id
                            ? segmentOpacity(for: segment)
                            : 0.2
                    )
                    .cornerRadius(3)
                }

                if let hoveredSegment {
                    RuleMark(x: .value("Selected time", midpoint(of: hoveredSegment)))
                        .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: chartStart...chartEnd)
            .chartYScale(domain: laneDomain)
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                    AxisTick().foregroundStyle(DashboardPalette.axisTick)
                    if let date = value.as(Date.self) {
                        AxisValueLabel(axisLabel(for: date))
                            .font(.caption2)
                            .foregroundStyle(DashboardPalette.axisText)
                    }
                }
            }
            .chartYAxis {
                if showsAllModels {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        if let modelID = value.as(String.self) {
                            AxisValueLabel {
                                Text(NativFormatting.truncateModelName(modelID, maxLength: 22))
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.axisText)
                            }
                        }
                    }
                }
            }
            .frame(height: chartHeight)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHoveredSegment(
                                        at: location,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                case .ended:
                                    hoveredSegmentID = nil
                                }
                            }

                        if let hoveredSegment,
                           let center = tooltipCenter(
                               for: hoveredSegment,
                               proxy: proxy,
                               geometry: geometry
                           ) {
                            SuccessRateHealthTooltip(
                                segment: hoveredSegment,
                                granularity: granularity,
                                showsModel: showsAllModels
                            )
                            .position(center)
                            .allowsHitTesting(false)
                            .transition(.identity)
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var segments: [Segment] {
        if showsAllModels {
            return modelPoints.map {
                Segment(
                    lane: $0.modelID,
                    bucketStart: $0.bucketStart,
                    requestsCompleted: $0.requestsCompleted,
                    requestsFailed: $0.requestsFailed
                )
            }
        }
        return points.map {
            Segment(
                lane: "Reliability",
                bucketStart: $0.bucketStart,
                requestsCompleted: $0.requestsCompleted,
                requestsFailed: $0.requestsFailed
            )
        }
    }

    private var laneDomain: [String] {
        showsAllModels
            ? DashboardModelColorScale.domain(for: modelPoints.map(\.modelID))
            : ["Reliability"]
    }

    private var hoveredSegment: Segment? {
        guard let hoveredSegmentID else { return nil }
        return segments.first { $0.id == hoveredSegmentID }
    }

    private var totalRequests: Int {
        points.reduce(0) { $0 + $1.requestsCompleted + $1.requestsFailed }
    }

    private var completedRequests: Int {
        points.reduce(0) { $0 + $1.requestsCompleted }
    }

    private var failedRequests: Int {
        points.reduce(0) { $0 + $1.requestsFailed }
    }

    private var overallRate: Double? {
        guard totalRequests > 0 else { return nil }
        return Double(completedRequests) / Double(totalRequests)
    }

    private var overallRateLabel: String {
        overallRate.map(NativFormatting.percent) ?? "--"
    }

    private var healthStatus: String {
        guard let overallRate else { return "No requests in this period" }
        if failedRequests == 0 { return "Running smoothly" }
        if overallRate >= 0.95 { return "Mostly healthy" }
        return "Needs attention"
    }

    private var granularity: NativAnalyticsGranularity {
        points.first?.granularity ?? (range == .last24Hours ? .hour : .day)
    }

    private var axisDates: [Date] {
        DashboardChartAxis.markDates(from: points.map(\.bucketStart), maximumCount: 6)
    }

    private var chartStart: Date {
        points.first?.bucketStart ?? Date()
    }

    private var chartEnd: Date {
        guard let last = points.last?.bucketStart else { return Date() }
        return bucketEnd(after: last)
    }

    private var chartHeight: CGFloat {
        max(118, min(CGFloat(laneDomain.count) * 30, 300))
    }

    private func color(for segment: Segment) -> Color {
        guard let successRate = segment.successRate else {
            return Color.secondary.opacity(0.18)
        }
        if segment.requestsFailed == 0 {
            return DashboardPalette.positive
        }
        if successRate >= 0.95 {
            return DashboardPalette.orange
        }
        return DashboardPalette.negative
    }

    private func segmentOpacity(for segment: Segment) -> Double {
        segment.totalRequests == 0 ? 0.45 : 0.92
    }

    private func bucketEnd(after date: Date) -> Date {
        switch granularity {
        case .hour:
            Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        case .day:
            Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
    }

    private func midpoint(of segment: Segment) -> Date {
        let end = bucketEnd(after: segment.bucketStart)
        return segment.bucketStart.addingTimeInterval(end.timeIntervalSince(segment.bucketStart) / 2)
    }

    private func axisLabel(for date: Date) -> String {
        DashboardChartAxis.label(for: date, granularity: granularity, range: range)
    }

    private func updateHoveredSegment(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredSegmentID = nil
            return
        }
        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredSegmentID = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        let plotY = location.y - plotFrame.minY
        guard let date: Date = proxy.value(atX: plotX) else {
            hoveredSegmentID = nil
            return
        }

        let lane: String
        if showsAllModels {
            guard let hoveredLane: String = proxy.value(atY: plotY) else {
                hoveredSegmentID = nil
                return
            }
            lane = hoveredLane
        } else {
            lane = "Reliability"
        }

        hoveredSegmentID = segments.first {
            $0.lane == lane
                && date >= $0.bucketStart
                && date < bucketEnd(after: $0.bucketStart)
        }?.id
    }

    private func tooltipCenter(
        for segment: Segment,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotX = proxy.position(forX: midpoint(of: segment)),
              let plotY = proxy.position(forY: segment.lane) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(width: 220, height: showsAllModels ? 124 : 106)
        let spacing: CGFloat = 12
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - spacing - tooltipSize.width / 2
            : anchor.x + spacing + tooltipSize.width / 2
        let desiredY = anchor.y - spacing - tooltipSize.height / 2

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(desiredY, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }
}

private struct SuccessRateHealthTooltip: View {
    let segment: SuccessRateHealthChart.Segment
    let granularity: NativAnalyticsGranularity
    let showsModel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsModel {
                Text(segment.lane)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            Divider()

            metricRow("Success", value: successRateLabel, color: DashboardPalette.positive)
            metricRow(
                "Requests",
                value: NativFormatting.integer(segment.totalRequests),
                color: DashboardPalette.indigo
            )
            metricRow(
                "Failed",
                value: NativFormatting.integer(segment.requestsFailed),
                color: DashboardPalette.negative
            )
        }
        .padding(11)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var successRateLabel: String {
        segment.successRate.map(NativFormatting.percent) ?? "--"
    }

    private var dateLabel: String {
        if granularity == .hour {
            return segment.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return segment.bucketStart.formatted(date: .long, time: .omitted)
    }

    private func metricRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ModelTokenUsageTooltip: View {
    let date: Date
    let points: [DashboardViewModel.ModelTokenPoint]
    let modelColorDomain: [String]
    let granularity: NativAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(points) { point in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(DashboardModelColorScale.color(for: point.modelID, in: modelColorDomain))
                                .frame(width: 7, height: 7)
                            Text(point.modelID)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(NativFormatting.integer(point.totalTokens))
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 190)

            Divider()

            HStack {
                Text("All models")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(NativFormatting.integer(totalTokens))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var totalTokens: Int {
        points.reduce(0) { $0 + $1.totalTokens }
    }

    private var dateLabel: String {
        if granularity == .hour {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

private struct ModelOverviewTooltip: View {
    let metric: DashboardOverviewMetric
    let date: Date
    let points: [DashboardViewModel.ModelTokenPoint]
    let modelColorDomain: [String]
    let ttftMilliseconds: Double?
    let granularity: NativAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(points) { point in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(DashboardModelColorScale.color(for: point.modelID, in: modelColorDomain))
                                .frame(width: 7, height: 7)
                            Text(point.modelID)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(valueLabel(for: point))
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 190)

            Divider()

            if metric == .requests, let ttftMilliseconds {
                HStack(spacing: 7) {
                    Circle()
                        .fill(DashboardPalette.latency)
                        .frame(width: 7, height: 7)
                    Text("Average TTFT")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(NativFormatting.milliseconds(ttftMilliseconds))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.caption)

                Divider()
            }

            HStack {
                Text("All models")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(summaryLabel)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func valueLabel(for point: DashboardViewModel.ModelTokenPoint) -> String {
        switch metric {
        case .tokens:
            NativFormatting.integer(point.totalTokens)
        case .requests:
            NativFormatting.integer(point.totalRequests)
        case .successRate:
            point.successRate.map(NativFormatting.percent) ?? "--"
        case .decodeSpeed:
            NativFormatting.rate(point.decodeSpeed)
        }
    }

    private var summaryLabel: String {
        switch metric {
        case .tokens:
            return NativFormatting.integer(points.reduce(0) { $0 + $1.totalTokens })
        case .requests:
            return NativFormatting.integer(points.reduce(0) { $0 + $1.totalRequests })
        case .successRate:
            guard totalRequests > 0 else { return "--" }
            let completed = points.reduce(0) { $0 + $1.requestsCompleted }
            return NativFormatting.percent(Double(completed) / Double(totalRequests))
        case .decodeSpeed:
            let decodeTokens = points.reduce(0) { $0 + $1.decodeTokensTotal }
            let decodeMilliseconds = points.reduce(Int64.zero) { $0 + $1.decodeTimeTotalMilliseconds }
            guard decodeTokens > 0, decodeMilliseconds > 0 else { return "--" }
            let speed = Double(decodeTokens) / (Double(decodeMilliseconds) / 1_000)
            return NativFormatting.rate(speed)
        }
    }

    private var totalRequests: Int {
        points.reduce(0) { $0 + $1.totalRequests }
    }

    private var dateLabel: String {
        if granularity == .hour {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

private struct TokenUsageTooltip: View {
    let point: DashboardViewModel.BucketPoint
    let granularity: NativAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            TokenUsageTooltipRow(
                title: "Input",
                value: point.promptTokensTotal,
                color: DashboardPalette.accent
            )
            TokenUsageTooltipRow(
                title: "Output",
                value: point.generatedTokensTotal,
                color: DashboardPalette.indigo
            )

            Divider()

            HStack {
                Text("Total")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 22)
                Text(NativFormatting.integer(point.processedTokensTotal))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 174)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var dateLabel: String {
        if granularity == .hour {
            return point.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return point.bucketStart.formatted(date: .long, time: .omitted)
    }
}

private struct TokenUsageTooltipRow: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
            }
            Spacer(minLength: 22)
            Text(NativFormatting.integer(value))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct DashboardMetricTooltip: View {
    let metric: DashboardOverviewMetric
    let point: DashboardViewModel.BucketPoint
    let granularity: NativAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            switch metric {
            case .tokens:
                EmptyView()
            case .requests:
                metricRow(
                    "Completed",
                    value: NativFormatting.integer(point.requestsCompleted),
                    color: DashboardPalette.positive
                )
                metricRow(
                    "Failed",
                    value: NativFormatting.integer(point.requestsFailed),
                    color: DashboardPalette.negative
                )
                metricRow(
                    "Average TTFT",
                    value: NativFormatting.milliseconds(point.averageTTFTMilliseconds),
                    color: DashboardPalette.latency
                )
            case .successRate:
                metricRow(
                    "Success rate",
                    value: successRate.map(NativFormatting.percent) ?? "--",
                    color: DashboardPalette.positive
                )
                metricRow(
                    "Requests",
                    value: NativFormatting.integer(totalRequests),
                    color: DashboardPalette.indigo
                )
                metricRow(
                    "Failed",
                    value: NativFormatting.integer(point.requestsFailed),
                    color: DashboardPalette.negative
                )
            case .decodeSpeed:
                metricRow(
                    "Decode speed",
                    value: NativFormatting.rate(decodeSpeed),
                    color: DashboardPalette.orange
                )
                metricRow(
                    "Generated",
                    value: "\(NativFormatting.integer(point.generatedTokensTotal)) tokens",
                    color: DashboardPalette.indigo
                )
            }
        }
        .padding(11)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var totalRequests: Int {
        point.requestsCompleted + point.requestsFailed
    }

    private var successRate: Double? {
        guard totalRequests > 0 else { return nil }
        return Double(point.requestsCompleted) / Double(totalRequests)
    }

    private var decodeSpeed: Double? {
        guard point.decodeTokensTotal > 0, point.decodeTimeTotalMilliseconds > 0 else {
            return nil
        }
        return Double(point.decodeTokensTotal) / (Double(point.decodeTimeTotalMilliseconds) / 1_000)
    }

    private var dateLabel: String {
        if granularity == .hour {
            return point.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return point.bucketStart.formatted(date: .long, time: .omitted)
    }

    private func metricRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ChartLegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RequestHealthPanel: View {
    let points: [DashboardViewModel.BucketPoint]
    let completed: Int
    let failed: Int
    let range: DashboardViewModel.RangeOption
    let minimumHeight: CGFloat
    @State private var hoveredPointID: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AnalyticsSectionHeader(
                title: "Request health",
                subtitle: "Completion volume and reliability"
            )

            HStack(alignment: .firstTextBaseline) {
                Text(total == 0 ? "--" : NativFormatting.percent(Double(completed) / Double(total)))
                    .font(.system(size: 29, weight: .semibold, design: .rounded).monospacedDigit())
                Text("successful")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if points.isEmpty {
                DashboardEmptyChart()
                    .frame(minHeight: 120, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Time", point.bucketStart),
                            y: .value("Completed", point.requestsCompleted)
                        )
                        .foregroundStyle(DashboardPalette.positive.gradient)
                        .cornerRadius(2)
                    }

                    if let hoveredPoint {
                        RuleMark(x: .value("Selected time", hoveredPoint.bucketStart))
                            .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        PointMark(
                            x: .value("Selected time", hoveredPoint.bucketStart),
                            y: .value("Completed", hoveredPoint.requestsCompleted)
                        )
                        .foregroundStyle(DashboardPalette.positive)
                        .symbolSize(42)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(DashboardPalette.axisTick)
                        if let date = value.as(Date.self) {
                            AxisValueLabel(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisText)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(minHeight: 118, maxHeight: .infinity)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateHoveredPoint(
                                            at: location,
                                            proxy: proxy,
                                            geometry: geometry
                                        )
                                    case .ended:
                                        hoveredPointID = nil
                                    }
                                }

                            if let hoveredPoint,
                               let tooltipCenter = tooltipCenter(
                                   for: hoveredPoint,
                                   proxy: proxy,
                                   geometry: geometry
                               ) {
                                RequestHealthTooltip(
                                    point: hoveredPoint,
                                    granularity: granularity
                                )
                                .position(tooltipCenter)
                                .allowsHitTesting(false)
                                .transition(.identity)
                            }
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                }
                .onChange(of: points) { _, newPoints in
                    if let hoveredPointID,
                       !newPoints.contains(where: { $0.id == hoveredPointID }) {
                        self.hoveredPointID = nil
                    }
                }
            }

            Divider()

            HStack {
                RequestHealthStat(title: "Completed", value: completed, color: DashboardPalette.positive)
                Spacer()
                RequestHealthStat(title: "Failed", value: failed, color: DashboardPalette.negative)
            }
        }
        .padding(18)
        .frame(minHeight: minimumHeight, alignment: .top)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var total: Int { completed + failed }

    private var hoveredPoint: DashboardViewModel.BucketPoint? {
        guard let hoveredPointID else { return nil }
        return points.first { $0.id == hoveredPointID }
    }

    private var granularity: NativAnalyticsGranularity {
        points.first?.granularity ?? .hour
    }

    private var axisDates: [Date] {
        DashboardChartAxis.markDates(from: points.map(\.bucketStart), maximumCount: 4)
    }

    private func axisLabel(for date: Date) -> String {
        DashboardChartAxis.label(
            for: date,
            granularity: granularity,
            range: range
        )
    }

    private func updateHoveredPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredPointID = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredPointID = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        guard let hoveredDate: Date = proxy.value(atX: plotX) else {
            hoveredPointID = nil
            return
        }

        let nextPoint = points.min {
            abs($0.bucketStart.timeIntervalSince(hoveredDate))
                < abs($1.bucketStart.timeIntervalSince(hoveredDate))
        }
        guard hoveredPointID != nextPoint?.id else { return }
        hoveredPointID = nextPoint?.id
    }

    private func tooltipCenter(
        for point: DashboardViewModel.BucketPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotX = proxy.position(forX: point.bucketStart),
              let plotY = proxy.position(forY: point.requestsCompleted) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(width: 210, height: 102)
        let spacing: CGFloat = 10
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - spacing - tooltipSize.width / 2
            : anchor.x + spacing + tooltipSize.width / 2
        let desiredY = anchor.y - spacing - tooltipSize.height / 2

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(desiredY, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }
}

private struct RequestHealthTooltip: View {
    let point: DashboardViewModel.BucketPoint
    let granularity: NativAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            HStack(spacing: 12) {
                metric("Completed", value: point.requestsCompleted, color: DashboardPalette.positive)
                metric("Failed", value: point.requestsFailed, color: DashboardPalette.negative)
            }

            Divider()

            HStack {
                Text("Total \(NativFormatting.integer(total))")
                Spacer(minLength: 8)
                Text(successRate)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(10)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var total: Int {
        point.requestsCompleted + point.requestsFailed
    }

    private var successRate: String {
        guard total > 0 else { return "--" }
        return NativFormatting.percent(Double(point.requestsCompleted) / Double(total))
    }

    private var dateLabel: String {
        if granularity == .hour {
            return point.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return point.bucketStart.formatted(date: .long, time: .omitted)
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Text(NativFormatting.integer(value))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct TokenUsagePanelHeightReader: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TokenUsagePanelHeightPreferenceKey.self,
                value: geometry.size.height
            )
        }
    }
}

private struct TokenUsagePanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RequestHealthStat: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(NativFormatting.compactCount(value).display)
                .font(.callout.weight(.semibold).monospacedDigit())
        }
    }
}

private struct ModelPerformanceTable: View {
    enum SortColumn: String {
        case model
        case tokens
        case requests
        case success
        case decode
        case peakMemory
    }

    let rows: [DashboardViewModel.ModelPerformance]
    let modelColorDomain: [String]
    let searchFocus: FocusState<Bool>.Binding

    @State private var searchText = ""
    @State private var sortColumn: SortColumn = .tokens
    @State private var sortAscending = false
    @State private var showsAllModels = false

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No model activity",
                    systemImage: "cpu",
                    description: Text("Model performance will appear after requests are processed.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ViewThatFits(in: .horizontal) {
                    tableContent
                        .frame(minWidth: minimumTableWidth, maxWidth: .infinity)

                    ScrollView(.horizontal) {
                        tableContent
                            .frame(width: minimumTableWidth)
                    }
                    .scrollIndicators(.visible)
                }
            }
        }
        .padding(.horizontal, 16)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var tableContent: some View {
        VStack(spacing: 0) {
            tableToolbar
            Divider().overlay(DashboardPalette.panelStroke)
            modelRowHeader

            if visibleRows.isEmpty {
                Divider().overlay(DashboardPalette.panelStroke)
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows) { row in
                        Divider().overlay(DashboardPalette.panelStroke)
                        modelRow(row)
                    }
                }
            }
        }
    }

    private var tableToolbar: some View {
        HStack(spacing: 12) {
            TextField("Search models", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused(searchFocus)
                .onSubmit {
                    searchFocus.wrappedValue = false
                }
                .frame(width: 260)

            Spacer(minLength: 16)

            Text("Showing \(visibleRows.count) of \(sortedRows.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if searchText.isEmpty, sortedRows.count > defaultVisibleLimit {
                Button(showsAllModels ? "Show top \(defaultVisibleLimit)" : "Show all") {
                    searchFocus.wrappedValue = false
                    showsAllModels.toggle()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 12)
    }

    private var modelRowHeader: some View {
        HStack(spacing: 18) {
            sortableHeader("Model", column: .model, width: nil, alignment: .leading)
            sortableHeader("Tokens", column: .tokens, width: 105, alignment: .trailing)
            sortableHeader("Requests", column: .requests, width: 90, alignment: .trailing)
            sortableHeader("Success", column: .success, width: 85, alignment: .trailing)
            sortableHeader("Decode", column: .decode, width: 105, alignment: .trailing)
            sortableHeader("Peak memory", column: .peakMemory, width: 105, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    private func modelRow(_ row: DashboardViewModel.ModelPerformance) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                ModelPerformanceProviderBadge(modelID: row.modelID)

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(modelColor(for: row.modelID))
                    .frame(width: 3, height: 24)

                Text(row.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help(row.modelID)
            }
            .frame(minWidth: modelColumnMinimumWidth, maxWidth: .infinity, alignment: .leading)

            tableValue(NativFormatting.compactCount(row.processedTokens).display, width: 105)
            tableValue(NativFormatting.integer(row.totalRequests), width: 90)
            tableValue(row.successRate.map(NativFormatting.percent) ?? "--", width: 85)
            tableValue(NativFormatting.rate(row.averageDecodeTokensPerSecond), width: 105)
            tableValue(NativFormatting.gigabytes(fromBytes: row.peakMemoryBytes), width: 105)
        }
        .padding(.vertical, 13)
    }

    private func sortableHeader(
        _ title: String,
        column: SortColumn,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        Group {
            if let width {
                sortButton(title, column: column)
                    .frame(width: width, alignment: alignment)
            } else {
                sortButton(title, column: column).frame(
                    minWidth: modelColumnMinimumWidth,
                    maxWidth: .infinity,
                    alignment: alignment
                )
            }
        }
    }

    private func sortButton(_ title: String, column: SortColumn) -> some View {
        Button {
            searchFocus.wrappedValue = false
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = column == .model
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    private func tableValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }

    private var filteredRows: [DashboardViewModel.ModelPerformance] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.modelID.localizedCaseInsensitiveContains(query) }
    }

    private var sortedRows: [DashboardViewModel.ModelPerformance] {
        filteredRows.sorted(by: comesBefore)
    }

    private var visibleRows: [DashboardViewModel.ModelPerformance] {
        if showsAllModels || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sortedRows
        }
        return Array(sortedRows.prefix(defaultVisibleLimit))
    }

    private func comesBefore(
        _ lhs: DashboardViewModel.ModelPerformance,
        _ rhs: DashboardViewModel.ModelPerformance
    ) -> Bool {
        if sortColumn == .model {
            let comparison = lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID)
            if comparison == .orderedSame { return lhs.modelID < rhs.modelID }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        let lhsValue = numericSortValue(for: lhs)
        let rhsValue = numericSortValue(for: rhs)
        switch (lhsValue, rhsValue) {
        case (.none, .none):
            return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
        case (.none, .some):
            return false
        case (.some, .none):
            return true
        case (.some(let lhsValue), .some(let rhsValue)):
            if lhsValue == rhsValue {
                return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
            }
            return sortAscending ? lhsValue < rhsValue : lhsValue > rhsValue
        }
    }

    private func numericSortValue(for row: DashboardViewModel.ModelPerformance) -> Double? {
        switch sortColumn {
        case .model:
            nil
        case .tokens:
            Double(row.processedTokens)
        case .requests:
            Double(row.totalRequests)
        case .success:
            row.successRate
        case .decode:
            row.averageDecodeTokensPerSecond
        case .peakMemory:
            row.peakMemoryBytes.map(Double.init)
        }
    }

    private func modelColor(for modelID: String) -> Color {
        if modelColorDomain.contains(modelID) {
            return DashboardModelColorScale.color(for: modelID, in: modelColorDomain)
        }
        return DashboardModelColorScale.color(for: "Other", in: modelColorDomain)
    }

    private var defaultVisibleLimit: Int { 12 }
    private var modelColumnMinimumWidth: CGFloat { 280 }
    private var minimumTableWidth: CGFloat { 900 }
}

private struct SessionCardValue: Identifiable {
    let title: String
    let value: String
    let help: String?

    var id: String { title }
}

private struct SessionMetricCard: View {
    let card: SessionCardValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(card.value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dashboardPanelStyle()
        .help(card.help ?? card.value)
    }
}

private struct DashboardPickerContainer<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .dashboardPanelStyle(cornerRadius: 10)
    }
}

private struct DashboardPeriodSelector: View {
    @Binding var selection: DashboardViewModel.RangeOption

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DashboardViewModel.RangeOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == option ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.12), value: selection)
        .accessibilityLabel("Period")
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .dashboardPanelStyle(cornerRadius: 10)
        .help(value)
    }
}

private struct HistoricalChartCard<Content: View>: View {
    let title: String
    let help: String
    let content: Content

    init(title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                DashboardInfoButton(text: help)
            }

            content
        }
        .padding(16)
        .dashboardPanelStyle(cornerRadius: 14)
    }
}

private struct DashboardInfoButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DashboardInfoPopover(text: text)
        }
        .accessibilityLabel("More information")
        .accessibilityHint(text)
    }
}

private struct DashboardInfoPopover: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
    }
}

private struct ModelPerformanceProviderBadge: View {
    let modelID: String
    @Environment(\.colorScheme) private var colorScheme

    private var provider: LocalModelProvider? {
        LocalModelProviderResolver.resolve(
            repoID: modelID,
            modelType: nil,
            architectures: []
        )
    }

    private var backgroundColor: Color {
        if provider?.needsLightIconBackgroundInDarkMode == true, colorScheme == .dark {
            return Color.white.opacity(0.92)
        }
        return Color.secondary.opacity(0.10)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(provider.displayName)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 7 : 10, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .help(provider?.displayName ?? "Unknown provider")
    }
}

private struct DashboardRecentRequestsTable: View {
    let requests: [NativAnalyticsRequestEvent]
    @State private var selectedRequest: NativAnalyticsRequestEvent?

    var body: some View {
        Group {
            if requests.isEmpty {
                ContentUnavailableView(
                    "No recent requests",
                    systemImage: "list.bullet.rectangle",
                    description: Text("No requests match the current dashboard filters.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        DashboardRecentRequestsHeaderRow()

                        ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                            Divider()
                                .overlay(DashboardPalette.panelStroke)

                            DashboardRecentRequestRow(
                                request: request,
                                isAlternating: !index.isMultiple(of: 2)
                            ) {
                                selectedRequest = request
                            }
                        }
                    }
                    .frame(
                        minWidth: DashboardRecentRequestsColumn.minimumTableWidth,
                        alignment: .leading
                    )
                }
            }
        }
        .padding(16)
        .dashboardPanelStyle(cornerRadius: 14)
        .sheet(item: $selectedRequest) { request in
            RequestDetailView(request: request)
        }
    }
}

private struct DashboardRecentRequestRow: View {
    let request: NativAnalyticsRequestEvent
    let isAlternating: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            DashboardRecentRequestsDataRow(request: request)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            Rectangle()
                .fill(rowBackground)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DashboardPalette.accent)
                .frame(width: 3)
                .padding(.vertical, 7)
                .opacity(isHovered ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
        .help("Open request details")
    }

    private var rowBackground: Color {
        if isHovered {
            DashboardPalette.accent.opacity(0.09)
        } else if isAlternating {
            Color.white.opacity(0.01)
        } else {
            Color.clear
        }
    }
}

private struct RequestDetailView: View {
    let request: NativAnalyticsRequestEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Request details")
                        .font(.title2.weight(.semibold))
                    Text(request.completedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(request.modelID)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(request.requestID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                RequestDetailMetric(title: "Prompt tokens", value: NativFormatting.integer(request.promptTokens))
                RequestDetailMetric(title: "Output tokens", value: NativFormatting.integer(request.generatedTokens))
                RequestDetailMetric(title: "Elapsed", value: "\(NativFormatting.seconds(fromMilliseconds: request.requestElapsedMilliseconds))s")
                RequestDetailMetric(title: "Prefill", value: "\(NativFormatting.decimal(request.resolvedPrefillTokensPerSecond)) tok/s")
                RequestDetailMetric(title: "Decode", value: "\(NativFormatting.decimal(request.resolvedDecodeTokensPerSecond)) tok/s")
                RequestDetailMetric(title: "Peak memory", value: NativFormatting.gigabytes(fromBytes: request.peakMemoryBytes))
            }

            HStack(spacing: 10) {
                DashboardRequestBadge(
                    text: request.status == "completed" ? "Completed" : "Failed",
                    style: request.status == "completed" ? .finish : .failure
                )
                DashboardRequestBadge(
                    text: request.streaming ? "Streaming" : "Standard",
                    style: .text
                )
                Text(request.endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct RequestDetailMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dashboardPanelStyle(cornerRadius: 10)
    }
}

private struct DashboardRecentRequestsHeaderRow: View {
    var body: some View {
        HStack(spacing: DashboardRecentRequestsColumn.horizontalSpacing) {
            ForEach(DashboardRecentRequestsColumn.allCases, id: \.self) { column in
                Text(column.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: column.width, alignment: column.alignment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

private struct DashboardRecentRequestsDataRow: View {
    let request: NativAnalyticsRequestEvent

    var body: some View {
        HStack(spacing: DashboardRecentRequestsColumn.horizontalSpacing) {
            ForEach(DashboardRecentRequestsColumn.allCases, id: \.self) { column in
                cell(for: column)
                    .frame(width: column.width, alignment: column.alignment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .font(.body.monospacedDigit())
    }

    @ViewBuilder
    private func cell(for column: DashboardRecentRequestsColumn) -> some View {
        switch column {
        case .time:
            Text(request.completedAt.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
        case .model:
            Text(request.modelID)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(request.modelID)
        case .finish:
            DashboardRequestBadge(
                text: finishTitle,
                style: finishStyle,
                systemImage: finishIcon,
                isProminent: true
            )
            .help(finishTitle)
        case .mode:
            DashboardRequestBadge(
                text: modeTitle,
                style: modeStyle
            )
            .help(modeTitle)
        case .prompt:
            Text(NativFormatting.integer(request.promptTokens))
        case .completion:
            Text(NativFormatting.integer(request.completionTokens))
        case .prefill:
            Text(NativFormatting.decimal(request.resolvedPrefillTokensPerSecond))
        case .decode:
            Text(NativFormatting.decimal(request.resolvedDecodeTokensPerSecond))
        case .request:
            Text(NativFormatting.decimal(request.requestTokensPerSecond))
        case .elapsed:
            Text(NativFormatting.seconds(fromMilliseconds: request.requestElapsedMilliseconds))
        case .peakMemory:
            Text(NativFormatting.gigabytes(fromBytes: request.peakMemoryBytes))
        }
    }

    private var finishTitle: String {
        if request.status != "completed" {
            return "Failed"
        }

        if let finishReason = request.finishReason,
           !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NativFormatting.titleizedIdentifier(finishReason)
        }

        return "Completed"
    }

    private var finishStyle: DashboardRequestBadgeStyle {
        request.status == "completed" ? .finish : .failure
    }

    private var finishIcon: String? {
        guard request.status == "completed" else {
            return "exclamationmark.triangle.fill"
        }

        switch request.finishReason?.lowercased() {
        case "length", "max_tokens", "max_output_tokens":
            return "hourglass"
        case "tool_call", "tool_calls":
            return "hammer.fill"
        default:
            return nil
        }
    }

    private var modeTitle: String {
        if request.toolCalls {
            return "Tools"
        }
        if request.structuredOutput {
            return "JSON"
        }
        return "Text"
    }

    private var modeStyle: DashboardRequestBadgeStyle {
        if request.toolCalls {
            return .tools
        }
        if request.structuredOutput {
            return .json
        }
        return .text
    }
}

private struct DashboardRequestBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let style: DashboardRequestBadgeStyle
    let systemImage: String?
    let isProminent: Bool

    init(
        text: String,
        style: DashboardRequestBadgeStyle,
        systemImage: String? = nil,
        isProminent: Bool = false
    ) {
        self.text = text
        self.style = style
        self.systemImage = systemImage
        self.isProminent = isProminent
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(isProminent ? .semibold : .medium))
        .foregroundStyle(badgeForegroundColor)
        .padding(.horizontal, systemImage == nil ? 12 : 10)
        .padding(.vertical, isProminent ? 5.5 : 5)
        .background {
            if isProminent {
                Capsule(style: .continuous)
                    .fill(badgeBackgroundColor)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(badgeBackgroundColor)
            }
        }
        .overlay {
            if isProminent {
                Capsule(style: .continuous)
                    .stroke(
                        badgeForegroundColor.opacity(colorScheme == .light ? 0.18 : 0.22),
                        lineWidth: colorScheme == .light ? 0.8 : 0.7
                    )
            }
        }
        .shadow(
            color: badgeShadowColor,
            radius: isProminent ? (colorScheme == .light ? 2 : 3) : 0,
            y: isProminent ? 1 : 0
        )
    }

    private var badgeForegroundColor: Color {
        style.foregroundColor(for: colorScheme)
    }

    private var badgeBackgroundColor: Color {
        style.backgroundColor(for: colorScheme)
    }

    private var badgeShadowColor: Color {
        guard isProminent else { return .clear }
        return colorScheme == .light
            ? Color.black.opacity(0.08)
            : badgeBackgroundColor.opacity(0.28)
    }
}

private struct DashboardRequestBadgeStyle {
    let foregroundColor: Color
    let backgroundColor: Color
    let lightForegroundColor: Color?
    let lightBackgroundColor: Color?

    init(
        foregroundColor: Color,
        backgroundColor: Color,
        lightForegroundColor: Color? = nil,
        lightBackgroundColor: Color? = nil
    ) {
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.lightForegroundColor = lightForegroundColor
        self.lightBackgroundColor = lightBackgroundColor
    }

    func foregroundColor(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .light, let lightForegroundColor {
            return lightForegroundColor
        }
        return foregroundColor
    }

    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .light, let lightBackgroundColor {
            return lightBackgroundColor
        }
        return backgroundColor
    }

    static let finish = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.finishBadgeForeground,
        backgroundColor: DashboardPalette.finishBadgeBackground,
        lightForegroundColor: DashboardPalette.finishBadgeLightForeground,
        lightBackgroundColor: DashboardPalette.finishBadgeLightBackground
    )
    static let failure = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.failureBadgeForeground,
        backgroundColor: DashboardPalette.failureBadgeBackground
    )
    static let json = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.jsonBadgeForeground,
        backgroundColor: DashboardPalette.jsonBadgeBackground
    )
    static let tools = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.toolsBadgeForeground,
        backgroundColor: DashboardPalette.toolsBadgeBackground
    )
    static let text = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.textBadgeForeground,
        backgroundColor: DashboardPalette.textBadgeBackground
    )
}

private enum DashboardRecentRequestsColumn: CaseIterable {
    case time
    case model
    case finish
    case mode
    case prompt
    case completion
    case prefill
    case decode
    case request
    case elapsed
    case peakMemory

    static let horizontalSpacing: CGFloat = 24

    var title: String {
        switch self {
        case .time:
            "Time"
        case .model:
            "Model"
        case .finish:
            "Finish"
        case .mode:
            "Mode"
        case .prompt:
            "Prompt"
        case .completion:
            "Completion"
        case .prefill:
            "Prefill tok/s"
        case .decode:
            "Decode tok/s"
        case .request:
            "Request tok/s"
        case .elapsed:
            "Elapsed"
        case .peakMemory:
            "Peak memory"
        }
    }

    var width: CGFloat {
        switch self {
        case .time:
            130
        case .model:
            210
        case .finish:
            110
        case .mode:
            92
        case .prompt:
            86
        case .completion:
            104
        case .prefill, .decode, .request:
            132
        case .elapsed:
            92
        case .peakMemory:
            112
        }
    }

    var alignment: Alignment {
        switch self {
        case .time, .model:
            .leading
        case .finish, .mode:
            .center
        case .prompt, .completion, .prefill, .decode, .request, .elapsed, .peakMemory:
            .trailing
        }
    }

    static var minimumTableWidth: CGFloat {
        let contentWidth = allCases.reduce(CGFloat.zero) { partialResult, column in
            partialResult + column.width
        }
        let spacingWidth = CGFloat(max(allCases.count - 1, 0)) * horizontalSpacing
        return contentWidth + spacingWidth + 24
    }
}

private enum DashboardChartMetric {
    case processed
    case generated
    case prompt

    func value(for point: DashboardViewModel.BucketPoint) -> Double {
        switch self {
        case .processed:
            Double(point.processedTokensTotal)
        case .generated:
            Double(point.generatedTokensTotal)
        case .prompt:
            Double(point.promptTokensTotal)
        }
    }
}

private struct DashboardTokenChart: View {
    let points: [DashboardViewModel.BucketPoint]
    let range: DashboardViewModel.RangeOption
    let metric: DashboardChartMetric

    var body: some View {
        if points.isEmpty {
            DashboardEmptyChart()
        } else {
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Bucket", point.bucketStart),
                        y: .value("Value", metric.value(for: point))
                    )
                    .foregroundStyle(DashboardPalette.primaryBar)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let rawValue = value.as(Double.self) {
                        AxisValueLabel(centered: false) {
                            Text(yAxisLabel(for: rawValue))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private func yAxisLabel(for value: Double) -> String {
        NativFormatting.compactCount(Int(value.rounded())).display
    }

    private var chartGranularity: NativAnalyticsGranularity {
        points.first?.granularity ?? fallbackGranularity
    }

    private var fallbackGranularity: NativAnalyticsGranularity {
        switch range {
        case .last24Hours:
            .hour
        case .last7Days, .last30Days, .lastYear, .allTime:
            .day
        }
    }

    private var xAxisDates: [Date] {
        DashboardChartAxis.markDates(
            from: points.map(\.bucketStart),
            maximumCount: chartGranularity == .hour ? 6 : 5
        )
    }

    private func axisLabel(for date: Date) -> String {
        switch chartGranularity {
        case .hour:
            DashboardFormatters.hourLabel.string(from: date).lowercased()
        case .day:
            DashboardFormatters.dayLabel.string(from: date)
        }
    }
}

private struct DashboardRequestChart: View {
    let points: [DashboardViewModel.BucketPoint]
    let range: DashboardViewModel.RangeOption

    var body: some View {
        if points.isEmpty {
            DashboardEmptyChart()
        } else {
            Chart {
                ForEach(requestSegments) { segment in
                    BarMark(
                        x: .value("Bucket", segment.bucketStart),
                        y: .value("Requests", segment.count)
                    )
                    .foregroundStyle(segment.color)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let rawValue = value.as(Double.self) {
                        AxisValueLabel(centered: false) {
                            Text(NativFormatting.compactCount(Int(rawValue.rounded())).display)
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private var chartGranularity: NativAnalyticsGranularity {
        points.first?.granularity ?? fallbackGranularity
    }

    private var fallbackGranularity: NativAnalyticsGranularity {
        switch range {
        case .last24Hours:
            .hour
        case .last7Days, .last30Days, .lastYear, .allTime:
            .day
        }
    }

    private var xAxisDates: [Date] {
        DashboardChartAxis.markDates(
            from: points.map(\.bucketStart),
            maximumCount: chartGranularity == .hour ? 6 : 5
        )
    }

    private var requestSegments: [RequestSegment] {
        points.flatMap { point in
            var segments: [RequestSegment] = []
            if point.requestsFailed > 0 {
                segments.append(
                    RequestSegment(
                        bucketStart: point.bucketStart,
                        kind: "failed",
                        count: point.requestsFailed,
                        color: DashboardPalette.failureBar
                    )
                )
            }
            if point.requestsCompleted > 0 {
                segments.append(
                    RequestSegment(
                        bucketStart: point.bucketStart,
                        kind: "completed",
                        count: point.requestsCompleted,
                        color: DashboardPalette.successBar
                    )
                )
            }
            return segments
        }
    }

    private func axisLabel(for date: Date) -> String {
        switch chartGranularity {
        case .hour:
            DashboardFormatters.hourLabel.string(from: date).lowercased()
        case .day:
            DashboardFormatters.dayLabel.string(from: date)
        }
    }
}

private enum DashboardChartAxis {
    static func markDates(from dates: [Date], maximumCount: Int) -> [Date] {
        guard dates.count > maximumCount, maximumCount > 1 else {
            return dates
        }

        let step = Double(dates.count - 1) / Double(maximumCount - 1)
        var indexes = Set([0, dates.count - 1])

        for markIndex in 1..<(maximumCount - 1) {
            indexes.insert(Int(round(Double(markIndex) * step)))
        }

        return indexes
            .sorted()
            .map { dates[$0] }
    }

    static func label(
        for date: Date,
        granularity: NativAnalyticsGranularity,
        range: DashboardViewModel.RangeOption
    ) -> String {
        switch granularity {
        case .hour where range == .allTime:
            let day = DashboardFormatters.dayLabel.string(from: date)
            let hour = DashboardFormatters.hourLabel.string(from: date).lowercased()
            return "\(day)\n\(hour)"
        case .hour:
            return DashboardFormatters.hourLabel.string(from: date).lowercased()
        case .day:
            return DashboardFormatters.dayLabel.string(from: date)
        }
    }
}

private struct RequestSegment: Identifiable {
    let bucketStart: Date
    let kind: String
    let count: Int
    let color: Color

    var id: String {
        "\(bucketStart.timeIntervalSince1970)-\(kind)-\(count)"
    }
}

private struct DashboardEmptyChart: View {
    var body: some View {
        ContentUnavailableView(
            "No analytics yet",
            systemImage: "chart.bar.xaxis",
            description: Text("No data is available for the selected filters.")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

private enum DashboardPalette {
    static let accent = Color(red: 71 / 255, green: 151 / 255, blue: 232 / 255)
    static let indigo = Color(red: 119 / 255, green: 105 / 255, blue: 234 / 255)
    static let latency = Color(red: 71 / 255, green: 174 / 255, blue: 207 / 255)
    static let positive = Color(red: 62 / 255, green: 179 / 255, blue: 131 / 255)
    static let negative = Color(red: 225 / 255, green: 91 / 255, blue: 101 / 255)
    static let orange = Color(red: 232 / 255, green: 151 / 255, blue: 65 / 255)
    static let primaryBar = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
    static let successBar = Color(red: 68 / 255, green: 157 / 255, blue: 187 / 255)
    static let failureBar = Color(red: 181 / 255, green: 51 / 255, blue: 63 / 255)
    static let panelFill = Color(nsColor: .controlBackgroundColor)
    static let panelStroke = Color(nsColor: .separatorColor).opacity(0.6)
    static let axisLabel = Color(nsColor: .tertiaryLabelColor)
    static let axisText = Color(nsColor: .secondaryLabelColor)
    static let axisTick = Color(nsColor: .secondaryLabelColor).opacity(0.78)
    static let axisGrid = Color(nsColor: .separatorColor).opacity(0.72)
    static let finishBadgeForeground = Color(red: 150 / 255, green: 188 / 255, blue: 245 / 255)
    static let finishBadgeBackground = Color(red: 34 / 255, green: 58 / 255, blue: 100 / 255)
    static let finishBadgeLightForeground = Color(red: 34 / 255, green: 96 / 255, blue: 176 / 255)
    static let finishBadgeLightBackground = Color(red: 232 / 255, green: 241 / 255, blue: 253 / 255)
    static let failureBadgeForeground = Color(red: 245 / 255, green: 183 / 255, blue: 188 / 255)
    static let failureBadgeBackground = Color(red: 95 / 255, green: 28 / 255, blue: 36 / 255)
    static let jsonBadgeForeground = Color(red: 205 / 255, green: 245 / 255, blue: 140 / 255)
    static let jsonBadgeBackground = Color(red: 82 / 255, green: 122 / 255, blue: 36 / 255)
    static let toolsBadgeForeground = Color(red: 255 / 255, green: 220 / 255, blue: 145 / 255)
    static let toolsBadgeBackground = Color(red: 112 / 255, green: 76 / 255, blue: 18 / 255)
    static let textBadgeForeground = Color(nsColor: .secondaryLabelColor)
    static let textBadgeBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.28)
}

private enum DashboardModelColorScale {
    static let palette: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .cyan,
        .yellow,
        .mint,
        .indigo,
        .red,
        .teal,
        .brown,
    ]

    static func domain(for modelIDs: [String]) -> [String] {
        Array(Set(modelIDs)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func colors(for domain: [String]) -> [Color] {
        let modelDomain = domain.filter { $0 != "Other" }
        return domain.map { modelID -> Color in
            guard modelID != "Other" else { return Color.gray }
            let index = modelDomain.firstIndex(of: modelID) ?? 0
            return palette[index % palette.count]
        }
    }

    static func color(for modelID: String, in domain: [String]) -> Color {
        guard modelID != "Other" else { return .gray }
        let modelDomain = domain.filter { $0 != "Other" }
        guard let index = modelDomain.firstIndex(of: modelID) else {
            return .secondary
        }
        return palette[index % palette.count]
    }
}

private enum DashboardFormatters {
    static let hourLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "ha"
        return formatter
    }()

    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private struct DashboardPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DashboardPalette.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
            )
    }
}

private extension View {
    func dashboardPanelStyle(cornerRadius: CGFloat = 12) -> some View {
        modifier(DashboardPanelModifier(cornerRadius: cornerRadius))
    }
}
