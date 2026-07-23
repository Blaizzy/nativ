import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    struct ModelOption: Identifiable, Hashable, Sendable {
        static let allID = "__all_models__"
        static let all = ModelOption(id: allID, modelID: nil, title: "All")

        let id: String
        let modelID: String?
        let title: String

        var displayTitle: String {
            title == "All" ? title : NativFormatting.truncateModelName(title, maxLength: 52)
        }
    }

    enum RangeOption: String, CaseIterable, Identifiable, Sendable {
        case last24Hours
        case last7Days
        case last30Days
        case lastYear
        case allTime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .last24Hours:
                "Day"
            case .last7Days:
                "Week"
            case .last30Days:
                "Month"
            case .lastYear:
                "Year"
            case .allTime:
                "All time"
            }
        }

        var analyticsRange: NativAnalyticsRange {
            switch self {
            case .last24Hours:
                .last24Hours
            case .last7Days:
                .last7Days
            case .last30Days:
                .last30Days
            case .lastYear:
                .lastYear
            case .allTime:
                .allTime
            }
        }

        var defaultGranularity: NativAnalyticsGranularity {
            analyticsRange.granularity
        }

        var preferredBucketCount: Int? {
            switch self {
            case .last24Hours:
                24
            case .last7Days:
                7
            case .last30Days:
                30
            case .lastYear:
                365
            case .allTime:
                nil
            }
        }
    }

    struct BucketPoint: Identifiable, Hashable, Sendable {
        let granularity: NativAnalyticsGranularity
        let bucketStart: Date
        let promptTokensTotal: Int
        let completionTokensTotal: Int
        let generatedTokensTotal: Int
        let decodeTokensTotal: Int
        let requestsStarted: Int
        let requestsCompleted: Int
        let requestsFailed: Int
        let streamingRequests: Int
        let requestTimeTotalMilliseconds: Int64
        let decodeTimeTotalMilliseconds: Int64
        let averageTTFTMilliseconds: Double?
        let ttftSampleCount: Int
        let peakMemoryBytesMax: Int64?

        var id: Date { bucketStart }

        var processedTokensTotal: Int {
            promptTokensTotal + generatedTokensTotal
        }
    }

    struct ActivityPoint: Identifiable, Hashable, Sendable {
        let bucketStart: Date
        let requestCount: Int

        var id: Date { bucketStart }
    }

    struct ModelPerformance: Identifiable, Hashable, Sendable {
        let modelID: String
        let processedTokens: Int
        let requestsCompleted: Int
        let requestsFailed: Int
        let averageDecodeTokensPerSecond: Double?
        let peakMemoryBytes: Int64?

        var id: String { modelID }

        var totalRequests: Int {
            requestsCompleted + requestsFailed
        }

        var successRate: Double? {
            guard totalRequests > 0 else { return nil }
            return Double(requestsCompleted) / Double(totalRequests)
        }
    }

    struct ModelTokenPoint: Identifiable, Hashable, Sendable {
        let modelID: String
        let bucketStart: Date
        let totalTokens: Int
        let requestsCompleted: Int
        let requestsFailed: Int
        let generatedTokensTotal: Int
        let decodeTokensTotal: Int
        let decodeTimeTotalMilliseconds: Int64

        var id: String {
            "\(modelID):\(bucketStart.timeIntervalSince1970)"
        }

        var totalRequests: Int {
            requestsCompleted + requestsFailed
        }

        var successRate: Double? {
            guard totalRequests > 0 else { return nil }
            return Double(requestsCompleted) / Double(totalRequests)
        }

        var decodeSpeed: Double? {
            guard decodeTokensTotal > 0, decodeTimeTotalMilliseconds > 0 else {
                return nil
            }
            return Double(decodeTokensTotal) / (Double(decodeTimeTotalMilliseconds) / 1_000)
        }
    }

    @Published private(set) var availableModels: [ModelOption] = [.all]
    @Published private(set) var historicalSummary = NativHistoricalAnalyticsSummary.empty
    @Published private(set) var bucketPoints: [BucketPoint] = []
    @Published private(set) var hourlyActivityPoints: [ActivityPoint] = []
    @Published private(set) var modelPerformance: [ModelPerformance] = []
    @Published private(set) var modelTokenPoints: [ModelTokenPoint] = []
    @Published private(set) var recentRequestEvents: [NativAnalyticsRequestEvent] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var localModelError: String?
    @Published private(set) var appliedModelID: String = ModelOption.allID
    @Published var selectedModelID: String = ModelOption.allID {
        didSet {
            guard oldValue != selectedModelID else { return }
            scheduleModelSelectionReload()
        }
    }
    @Published var selectedRange: RangeOption = .last24Hours {
        didSet {
            guard oldValue != selectedRange else { return }
            reloadHistorical()
        }
    }

    private var analyticsDatabaseURL: URL
    private var preferredModelID: String?
    private var hasAppliedPreferredSelection = false
    private var scannedModelOptions: [ModelOption] = []
    private var historicalModelIDs: [String] = []
    private var modelScanTask: Task<Void, Never>?
    private var modelSelectionReloadTask: Task<Void, Never>?
    private var historyLoadTask: Task<DashboardSnapshot, Never>?
    private var historyLoadGeneration = 0

    init(analyticsDatabaseURL: URL = NativAnalyticsStore.defaultDatabaseURL()) {
        self.analyticsDatabaseURL = analyticsDatabaseURL.standardizedFileURL
    }

    deinit {
        modelScanTask?.cancel()
        modelSelectionReloadTask?.cancel()
        historyLoadTask?.cancel()
    }

    func updateAnalyticsDatabaseURL(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard analyticsDatabaseURL != standardizedURL else {
            return
        }
        analyticsDatabaseURL = standardizedURL
        reloadHistorical()
    }

    func updatePreferredModelID(_ modelID: String?) {
        preferredModelID = normalizedModelID(modelID)
        applyPreferredSelectionIfPossible()
    }

    func scanModels(at path: String, additionalPaths: [String] = []) {
        modelScanTask?.cancel()
        localModelError = nil

        modelScanTask = Task { [path] in
            do {
                let models = try await LocalModelDiscovery.scan(path: path, additionalPaths: additionalPaths)
                guard !Task.isCancelled else {
                    return
                }
                applyScannedModels(models)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                scannedModelOptions = []
                rebuildAvailableModels()
                localModelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if !availableModels.contains(where: { $0.id == selectedModelID }) {
                    selectedModelID = ModelOption.allID
                }
            }
        }
    }

    func reloadHistorical() {
        historyLoadTask?.cancel()
        isLoadingHistory = true
        historyLoadGeneration += 1

        let databaseURL = analyticsDatabaseURL
        let range = selectedRange
        let selectedModelID = selectedModelID == ModelOption.allID ? nil : selectedModelID
        let generation = historyLoadGeneration

        let task = Task.detached(priority: .userInitiated) {
            let store = NativAnalyticsStore(databaseURL: databaseURL)
            let displayGranularity = Self.displayGranularity(
                for: range,
                store: store,
                modelID: selectedModelID
            )
            let summary = store.fetchSummary(
                range: range.analyticsRange,
                modelID: selectedModelID,
                granularityOverride: displayGranularity
            )
            let rawBuckets = store.fetchBuckets(
                range: range.analyticsRange,
                modelID: selectedModelID,
                granularityOverride: displayGranularity
            )
            let rawActivityBuckets = store.fetchBuckets(
                range: range.analyticsRange,
                modelID: selectedModelID,
                granularityOverride: .hour
            )
            let ttftEvents = store.fetchTTFTEvents(
                range: range.analyticsRange,
                modelID: selectedModelID
            )
            let recentRequestEvents = store.fetchRecentRequestEvents(
                range: range.analyticsRange,
                modelID: selectedModelID,
                limit: 10
            )
            let knownModelIDs = store.fetchKnownModelIDs()
            let points = Self.bucketPoints(
                from: rawBuckets,
                ttftEvents: ttftEvents,
                range: range,
                granularity: displayGranularity
            )
            let activityPoints = Self.activityPoints(from: rawActivityBuckets)
            let modelPerformance = Self.modelPerformance(from: rawBuckets)
            let servedModelIDs = Set(modelPerformance.map(\.modelID))
            let modelBuckets = rawBuckets.filter { servedModelIDs.contains($0.modelID) }
            let leadingModelIDs = Set(modelPerformance.prefix(12).map(\.modelID))
            let modelTokenPoints = Self.modelTokenPoints(
                from: modelBuckets,
                bucketDates: points.map(\.bucketStart),
                leadingModelIDs: leadingModelIDs,
                groupsRemainingModels: modelPerformance.count > 12
            )
            return DashboardSnapshot(
                summary: summary,
                points: points,
                activityPoints: activityPoints,
                modelPerformance: modelPerformance,
                modelTokenPoints: modelTokenPoints,
                knownModelIDs: knownModelIDs,
                recentRequestEvents: recentRequestEvents
            )
        }
        historyLoadTask = task

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await task.value
            guard !Task.isCancelled else { return }
            guard historyLoadGeneration == generation else { return }
            historicalSummary = snapshot.summary
            bucketPoints = snapshot.points
            hourlyActivityPoints = snapshot.activityPoints
            modelPerformance = snapshot.modelPerformance
            modelTokenPoints = snapshot.modelTokenPoints
            appliedModelID = selectedModelID ?? ModelOption.allID
            historicalModelIDs = snapshot.knownModelIDs
            rebuildAvailableModels()
            if !availableModels.contains(where: { $0.id == self.selectedModelID }) {
                self.selectedModelID = ModelOption.allID
            }
            recentRequestEvents = snapshot.recentRequestEvents
            isLoadingHistory = false
        }
    }

    private func scheduleModelSelectionReload() {
        modelSelectionReloadTask?.cancel()

        modelSelectionReloadTask = Task { @MainActor [weak self] in
            do {
                // Let AppKit finish dismissing the model menu before invalidating
                // the chart hierarchy and starting the filtered analytics load.
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            modelSelectionReloadTask = nil
            reloadHistorical()
        }
    }

    private func applyScannedModels(_ models: [LocalModel]) {
        scannedModelOptions = models.map {
            ModelOption(id: $0.repoID, modelID: $0.repoID, title: $0.repoID)
        }
        rebuildAvailableModels()
        localModelError = nil
        applyPreferredSelectionIfPossible()

        guard availableModels.contains(where: { $0.id == selectedModelID }) else {
            selectedModelID = ModelOption.allID
            return
        }
    }

    private func rebuildAvailableModels() {
        var optionsByID = Dictionary(uniqueKeysWithValues: scannedModelOptions.map { ($0.id, $0) })
        for modelID in historicalModelIDs where optionsByID[modelID] == nil {
            optionsByID[modelID] = ModelOption(id: modelID, modelID: modelID, title: modelID)
        }
        availableModels = [.all] + optionsByID.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        applyPreferredSelectionIfPossible()
    }

    private func applyPreferredSelectionIfPossible() {
        guard !hasAppliedPreferredSelection else {
            return
        }

        guard let preferredModelID else {
            hasAppliedPreferredSelection = true
            return
        }

        guard availableModels.contains(where: { $0.modelID == preferredModelID }) else {
            return
        }

        hasAppliedPreferredSelection = true
        selectedModelID = preferredModelID
    }

    private func normalizedModelID(_ modelID: String?) -> String? {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension DashboardViewModel {
    nonisolated static let maximumAllTimeHourlyBucketCount = 72

    struct DashboardSnapshot: Sendable {
        let summary: NativHistoricalAnalyticsSummary
        let points: [BucketPoint]
        let activityPoints: [ActivityPoint]
        let modelPerformance: [ModelPerformance]
        let modelTokenPoints: [ModelTokenPoint]
        let knownModelIDs: [String]
        let recentRequestEvents: [NativAnalyticsRequestEvent]
    }

    nonisolated static func activityPoints(
        from rawBuckets: [NativAnalyticsBucketPoint]
    ) -> [ActivityPoint] {
        guard !rawBuckets.isEmpty else {
            return []
        }

        let grouped = Dictionary(grouping: rawBuckets, by: \.bucketStart)
        return grouped.keys.sorted().map { bucketStart in
            let rows = grouped[bucketStart, default: []]
            let started = rows.reduce(0) { $0 + $1.requestsStarted }
            let finished = rows.reduce(0) { $0 + $1.requestsCompleted + $1.requestsFailed }
            return ActivityPoint(
                bucketStart: bucketStart,
                requestCount: max(started, finished)
            )
        }
    }

    nonisolated static func modelPerformance(
        from buckets: [NativAnalyticsBucketPoint]
    ) -> [ModelPerformance] {
        Dictionary(grouping: buckets, by: \.modelID)
            .compactMap { modelID, rows in
                let requestsCompleted = rows.reduce(0) { $0 + $1.requestsCompleted }
                guard requestsCompleted > 0 else {
                    return nil
                }

                let decodeTokens = rows.reduce(0) { $0 + $1.decodeTokensTotal }
                let decodeMilliseconds = rows.reduce(Int64.zero) { $0 + $1.decodeTimeTotalMilliseconds }
                let decodeRate: Double? = decodeTokens > 0 && decodeMilliseconds > 0
                    ? Double(decodeTokens) / (Double(decodeMilliseconds) / 1_000)
                    : nil

                return ModelPerformance(
                    modelID: modelID,
                    processedTokens: rows.reduce(0) { $0 + $1.totalProcessedTokens },
                    requestsCompleted: requestsCompleted,
                    requestsFailed: rows.reduce(0) { $0 + $1.requestsFailed },
                    averageDecodeTokensPerSecond: decodeRate,
                    peakMemoryBytes: rows.compactMap(\.peakMemoryBytesMax).max()
                )
            }
            .sorted { lhs, rhs in
                if lhs.processedTokens == rhs.processedTokens {
                    return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
                }
                return lhs.processedTokens > rhs.processedTokens
            }
    }

    nonisolated static func modelTokenPoints(
        from buckets: [NativAnalyticsBucketPoint],
        bucketDates: [Date],
        leadingModelIDs: Set<String>,
        groupsRemainingModels: Bool
    ) -> [ModelTokenPoint] {
        let rowsByModel = Dictionary(grouping: buckets) { bucket in
            if groupsRemainingModels, !leadingModelIDs.contains(bucket.modelID) {
                return "Other"
            }
            return bucket.modelID
        }

        return rowsByModel.flatMap { modelID, rows in
            let rowsByDate = Dictionary(grouping: rows, by: \.bucketStart)
            return bucketDates.map { bucketStart in
                let bucketRows = rowsByDate[bucketStart, default: []]
                return ModelTokenPoint(
                    modelID: modelID,
                    bucketStart: bucketStart,
                    totalTokens: bucketRows.reduce(0) { $0 + $1.totalProcessedTokens },
                    requestsCompleted: bucketRows.reduce(0) { $0 + $1.requestsCompleted },
                    requestsFailed: bucketRows.reduce(0) { $0 + $1.requestsFailed },
                    generatedTokensTotal: bucketRows.reduce(0) { $0 + $1.generatedTokensTotal },
                    decodeTokensTotal: bucketRows.reduce(0) { $0 + $1.decodeTokensTotal },
                    decodeTimeTotalMilliseconds: bucketRows.reduce(0) { $0 + $1.decodeTimeTotalMilliseconds }
                )
            }
        }
        .sorted {
            if $0.bucketStart == $1.bucketStart {
                return $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending
            }
            return $0.bucketStart < $1.bucketStart
        }
    }

    nonisolated static func bucketPoints(
        from rawBuckets: [NativAnalyticsBucketPoint],
        ttftEvents: [NativAnalyticsTTFTEvent] = [],
        range: RangeOption,
        granularity: NativAnalyticsGranularity,
        calendar: Calendar = .current
    ) -> [BucketPoint] {
        guard !rawBuckets.isEmpty else {
            return []
        }

        let grouped = Dictionary(grouping: rawBuckets, by: \.bucketStart)
        let ttftByBucket = Dictionary(grouping: ttftEvents) { event in
            normalizedBucketDate(
                for: event.completedAt,
                granularity: granularity,
                calendar: calendar
            )
        }
        let filledDates = bucketDates(
            from: rawBuckets.map(\.bucketStart),
            range: range,
            granularity: granularity,
            calendar: calendar
        )

        return filledDates.map { bucketStart in
            let rows = grouped[bucketStart] ?? []
            let ttftSamples = ttftByBucket[bucketStart, default: []]
            let averageTTFT = ttftSamples.isEmpty
                ? nil
                : Double(ttftSamples.reduce(Int64.zero) { $0 + $1.milliseconds })
                    / Double(ttftSamples.count)
            return BucketPoint(
                granularity: rows.first?.granularity ?? granularity,
                bucketStart: bucketStart,
                promptTokensTotal: rows.reduce(0) { $0 + $1.promptTokensTotal },
                completionTokensTotal: rows.reduce(0) { $0 + $1.completionTokensTotal },
                generatedTokensTotal: rows.reduce(0) { $0 + $1.generatedTokensTotal },
                decodeTokensTotal: rows.reduce(0) { $0 + $1.decodeTokensTotal },
                requestsStarted: rows.reduce(0) { $0 + $1.requestsStarted },
                requestsCompleted: rows.reduce(0) { $0 + $1.requestsCompleted },
                requestsFailed: rows.reduce(0) { $0 + $1.requestsFailed },
                streamingRequests: rows.reduce(0) { $0 + $1.streamingRequests },
                requestTimeTotalMilliseconds: rows.reduce(0) { $0 + $1.requestTimeTotalMilliseconds },
                decodeTimeTotalMilliseconds: rows.reduce(0) { $0 + $1.decodeTimeTotalMilliseconds },
                averageTTFTMilliseconds: averageTTFT,
                ttftSampleCount: ttftSamples.count,
                peakMemoryBytesMax: rows.compactMap(\.peakMemoryBytesMax).max()
            )
        }
    }

    nonisolated static func bucketDates(
        from rawDates: [Date],
        range: RangeOption,
        granularity: NativAnalyticsGranularity,
        calendar: Calendar
    ) -> [Date] {
        guard let firstRawDate = rawDates.min(),
              let lastRawDate = rawDates.max()
        else {
            return []
        }

        let end = normalizedBucketDate(
            for: max(lastRawDate, Date()),
            granularity: granularity,
            calendar: calendar
        )

        let dates: [Date]
        if let preferredBucketCount = range.preferredBucketCount {
            let start = offset(
                end,
                by: -(preferredBucketCount - 1),
                granularity: granularity,
                calendar: calendar
            )
            dates = strideDates(
                from: start,
                through: end,
                granularity: granularity,
                calendar: calendar
            )
        } else {
            let start = normalizedBucketDate(
                for: firstRawDate,
                granularity: granularity,
                calendar: calendar
            )
            dates = strideDates(
                from: start,
                through: normalizedBucketDate(
                    for: lastRawDate,
                    granularity: granularity,
                    calendar: calendar
                ),
                granularity: granularity,
                calendar: calendar
            )
        }

        return dates
    }

    nonisolated static func displayGranularity(
        for range: RangeOption,
        store: NativAnalyticsStore,
        modelID: String?,
        calendar: Calendar = .current
    ) -> NativAnalyticsGranularity {
        guard range == .allTime else {
            return range.defaultGranularity
        }

        guard let bounds = store.fetchBucketDateBounds(granularity: .hour, modelID: modelID) else {
            return .day
        }

        let start = normalizedBucketDate(
            for: bounds.start,
            granularity: .hour,
            calendar: calendar
        )
        let end = normalizedBucketDate(
            for: bounds.end,
            granularity: .hour,
            calendar: calendar
        )
        let hourSpan = (calendar.dateComponents([.hour], from: start, to: end).hour ?? 0) + 1

        return hourSpan <= maximumAllTimeHourlyBucketCount ? .hour : .day
    }

    nonisolated static func strideDates(
        from start: Date,
        through end: Date,
        granularity: NativAnalyticsGranularity,
        calendar: Calendar
    ) -> [Date] {
        var dates: [Date] = []
        var current = start
        while current <= end {
            dates.append(current)
            current = offset(current, by: 1, granularity: granularity, calendar: calendar)
        }
        return dates
    }

    nonisolated static func offset(
        _ date: Date,
        by amount: Int,
        granularity: NativAnalyticsGranularity,
        calendar: Calendar
    ) -> Date {
        switch granularity {
        case .hour:
            return calendar.date(byAdding: .hour, value: amount, to: date) ?? date
        case .day:
            return calendar.date(byAdding: .day, value: amount, to: date) ?? date
        }
    }

    nonisolated static func normalizedBucketDate(
        for date: Date,
        granularity: NativAnalyticsGranularity,
        calendar: Calendar
    ) -> Date {
        switch granularity {
        case .hour:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: components) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}
