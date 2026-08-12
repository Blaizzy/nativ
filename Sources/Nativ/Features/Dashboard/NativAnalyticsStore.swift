import Foundation
import SQLite3

enum NativAnalyticsRange: CaseIterable {
    case last24Hours
    case last7Days
    case last30Days
    case lastYear
    case allTime

    var granularity: NativAnalyticsGranularity {
        switch self {
        case .last24Hours:
            return .hour
        case .last7Days, .last30Days, .lastYear, .allTime:
            return .day
        }
    }

    var trailingInterval: TimeInterval? {
        switch self {
        case .last24Hours:
            return 24 * 60 * 60
        case .last7Days:
            return 7 * 24 * 60 * 60
        case .last30Days:
            return 30 * 24 * 60 * 60
        case .lastYear:
            return 365 * 24 * 60 * 60
        case .allTime:
            return nil
        }
    }

    var rangeStartUnix: Double? {
        guard let trailingInterval else {
            return nil
        }
        return Date().addingTimeInterval(-trailingInterval).timeIntervalSince1970
    }
}

enum NativAnalyticsGranularity: String {
    case hour
    case day
}

struct NativHistoricalAnalyticsSummary: Sendable {
    static let empty = NativHistoricalAnalyticsSummary()

    var requestsCompleted: Int = 0
    var requestsFailed: Int = 0
    var promptTokensTotal: Int = 0
    var completionTokensTotal: Int = 0
    var generatedTokensTotal: Int = 0
    var decodeTokensTotal: Int = 0
    var requestTimeTotalMilliseconds: Int64 = 0
    var decodeTimeTotalMilliseconds: Int64 = 0
    var averageTTFTMilliseconds: Double?
    var ttftSampleCount: Int = 0
    var peakMemoryBytesMax: Int64?
    var lastUpdatedAt: Date?

    var totalProcessedTokens: Int {
        promptTokensTotal + generatedTokensTotal
    }

    var averageDecodeTokensPerSecond: Double? {
        guard decodeTokensTotal > 0, decodeTimeTotalMilliseconds > 0 else {
            return nil
        }
        return Double(decodeTokensTotal) / (Double(decodeTimeTotalMilliseconds) / 1_000)
    }

    var averageRequestTokensPerSecond: Double? {
        guard completionTokensTotal > 0, requestTimeTotalMilliseconds > 0 else {
            return nil
        }
        return Double(completionTokensTotal) / (Double(requestTimeTotalMilliseconds) / 1_000)
    }

    var asAllTimeStats: NativAllTimeStats {
        NativAllTimeStats(
            requestsCompleted: requestsCompleted,
            requestsFailed: requestsFailed,
            promptTokensTotal: promptTokensTotal,
            completionTokensTotal: completionTokensTotal,
            generatedTokensTotal: generatedTokensTotal,
            decodeTokensTotal: decodeTokensTotal,
            requestTimeTotalSeconds: Double(requestTimeTotalMilliseconds) / 1_000,
            decodeTimeTotalSeconds: Double(decodeTimeTotalMilliseconds) / 1_000,
            lastUpdated: lastUpdatedAt
        )
    }
}

struct NativAnalyticsBucketPoint: Identifiable, Sendable {
    let granularity: NativAnalyticsGranularity
    let bucketStart: Date
    let modelID: String
    let requestsStarted: Int
    let requestsCompleted: Int
    let requestsFailed: Int
    let streamingRequests: Int
    let promptTokensTotal: Int
    let completionTokensTotal: Int
    let generatedTokensTotal: Int
    let decodeTokensTotal: Int
    let requestTimeTotalMilliseconds: Int64
    let decodeTimeTotalMilliseconds: Int64
    let peakMemoryBytesMax: Int64?
    let updatedAt: Date?

    var id: String {
        "\(granularity.rawValue):\(bucketStart.timeIntervalSince1970):\(modelID)"
    }

    var totalProcessedTokens: Int {
        promptTokensTotal + generatedTokensTotal
    }
}

struct NativAnalyticsRequestEvent: Identifiable, Sendable {
    let requestID: String
    let completedAt: Date
    let modelID: String
    let status: String
    let endpoint: String
    let streaming: Bool
    let promptTokens: Int
    let completionTokens: Int
    let generatedTokens: Int
    let requestElapsedMilliseconds: Int64?
    let decodeElapsedMilliseconds: Int64?
    let ttftMilliseconds: Int64?
    let peakMemoryBytes: Int64?
    let prefillTokensPerSecond: Double?
    let decodeTokensPerSecond: Double?
    let imageCount: Int
    let audioCount: Int
    let structuredOutput: Bool
    let thinkingEnabled: Bool
    let toolCalls: Bool
    let finishReason: String?
    let backend: String?

    var id: String { requestID }

    var requestTokensPerSecond: Double? {
        guard completionTokens > 0,
              let requestElapsedMilliseconds,
              requestElapsedMilliseconds > 0
        else {
            return nil
        }

        return Double(completionTokens) / (Double(requestElapsedMilliseconds) / 1_000)
    }

    var resolvedPrefillTokensPerSecond: Double? {
        if let prefillTokensPerSecond,
           prefillTokensPerSecond > 0,
           prefillTokensPerSecond.isFinite {
            return prefillTokensPerSecond
        }

        guard promptTokens > 0,
              let ttftMilliseconds,
              ttftMilliseconds > 0
        else {
            return nil
        }

        return Double(promptTokens) / (Double(ttftMilliseconds) / 1_000)
    }

    var resolvedDecodeTokensPerSecond: Double? {
        if let decodeTokensPerSecond,
           decodeTokensPerSecond > 0,
           decodeTokensPerSecond.isFinite {
            return decodeTokensPerSecond
        }

        let decodeTokenCount = generatedTokens > 0 ? generatedTokens : completionTokens
        guard decodeTokenCount > 0 else {
            return nil
        }

        if let decodeElapsedMilliseconds,
           decodeElapsedMilliseconds > 0 {
            return Double(decodeTokenCount) / (Double(decodeElapsedMilliseconds) / 1_000)
        }

        if let requestElapsedMilliseconds,
           requestElapsedMilliseconds > 0 {
            return Double(decodeTokenCount) / (Double(requestElapsedMilliseconds) / 1_000)
        }

        return nil
    }
}

struct NativAnalyticsTTFTEvent: Sendable {
    let completedAt: Date
    let milliseconds: Int64
}

final class NativAnalyticsStore {
    private let databaseURL: URL
    // Keep one read connection for a dashboard snapshot. Opening a connection
    // for every metric query repeats schema setup and WAL configuration, and
    // makes one reload look like several independent database passes.
    private let connection: SQLiteConnection?

    init(databaseURL: URL = NativAnalyticsStore.defaultDatabaseURL()) {
        let standardizedURL = databaseURL.standardizedFileURL
        self.databaseURL = standardizedURL
        self.connection = try? SQLiteConnection(url: standardizedURL)
    }

    static func defaultDatabaseURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupport
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Analytics.sqlite3")
    }

    /// Runs a group of dashboard reads against one consistent SQLite snapshot.
    /// The connection is shared by all fetch methods on this store, so a reload
    /// does not repeatedly open/configure the database or observe mixed writes.
    func withReadSnapshot<Result>(_ work: () -> Result) -> Result {
        guard let connection else {
            return work()
        }

        try? connection.execute("BEGIN TRANSACTION;")
        defer { try? connection.execute("COMMIT;") }
        return work()
    }

    func fetchSummary(
        range: NativAnalyticsRange = .allTime,
        modelID: String? = nil,
        granularityOverride: NativAnalyticsGranularity? = nil
    ) -> NativHistoricalAnalyticsSummary {
        guard let connection else {
            return .empty
        }

        let granularity = granularityOverride ?? range.granularity

        let sql = """
            SELECT
                COALESCE(SUM(requests_completed), 0),
                COALESCE(SUM(requests_failed), 0),
                COALESCE(SUM(prompt_tokens_total), 0),
                COALESCE(SUM(completion_tokens_total), 0),
                COALESCE(SUM(generated_tokens_total), 0),
                COALESCE(SUM(request_elapsed_ms_total), 0),
                COALESCE(SUM(decode_elapsed_ms_total), 0),
                MAX(peak_memory_bytes_max),
                MAX(updated_at)
            FROM analytics_buckets
            WHERE granularity = ?
            \(range.rangeStartUnix == nil ? "" : "AND bucket_start >= ?")
            \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            """

        guard let statement = try? connection.prepare(sql) else {
            return .empty
        }

        bindBucketFilters(
            statement: statement,
            granularity: granularity,
            rangeStartUnix: range.rangeStartUnix,
            modelID: modelID
        )

        guard (try? statement.step()) == true else {
            return .empty
        }

        let ttftSummary = fetchTTFTSummary(
            connection: connection,
            range: range,
            modelID: modelID
        )
        let decodeSummary = fetchDecodeSummary(
            connection: connection,
            range: range,
            modelID: modelID
        )

        return NativHistoricalAnalyticsSummary(
            requestsCompleted: Int(statement.int64(at: 0)),
            requestsFailed: Int(statement.int64(at: 1)),
            promptTokensTotal: Int(statement.int64(at: 2)),
            completionTokensTotal: Int(statement.int64(at: 3)),
            generatedTokensTotal: Int(statement.int64(at: 4)),
            decodeTokensTotal: decodeSummary.tokens,
            requestTimeTotalMilliseconds: statement.int64(at: 5),
            decodeTimeTotalMilliseconds: decodeSummary.milliseconds,
            averageTTFTMilliseconds: ttftSummary.averageMilliseconds,
            ttftSampleCount: ttftSummary.sampleCount,
            peakMemoryBytesMax: statement.isNull(at: 7) ? nil : statement.int64(at: 7),
            lastUpdatedAt: statement.isNull(at: 8)
                ? nil
                : Date(timeIntervalSince1970: statement.double(at: 8))
        )
    }

    private func fetchDecodeSummary(
        connection: SQLiteConnection,
        range: NativAnalyticsRange,
        modelID: String?
    ) -> (tokens: Int, milliseconds: Int64) {
        let sql = """
            SELECT
                COALESCE(SUM(\(decodeSampleTokensSQL)), 0),
                COALESCE(SUM(\(decodeSampleMillisecondsSQL)), 0)
            FROM request_events
            WHERE status = 'completed'
            \(range.rangeStartUnix == nil ? "" : "AND completed_at >= ?")
            \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            """

        guard let statement = try? connection.prepare(sql) else {
            return (0, 0)
        }

        var parameterIndex: Int32 = 1
        if let rangeStartUnix = range.rangeStartUnix {
            statement.bind(double: rangeStartUnix, at: parameterIndex)
            parameterIndex += 1
        }
        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: parameterIndex)
        }

        guard (try? statement.step()) == true else {
            return (0, 0)
        }
        return (
            tokens: Int(statement.int64(at: 0)),
            milliseconds: statement.int64(at: 1)
        )
    }

    private func fetchTTFTSummary(
        connection: SQLiteConnection,
        range: NativAnalyticsRange,
        modelID: String?
    ) -> (averageMilliseconds: Double?, sampleCount: Int) {
        let sql = """
            SELECT AVG(ttft_ms), COUNT(ttft_ms)
            FROM request_events
            WHERE ttft_ms IS NOT NULL
                AND ttft_ms >= 0
            \(range.rangeStartUnix == nil ? "" : "AND completed_at >= ?")
            \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            """

        guard let statement = try? connection.prepare(sql) else {
            return (nil, 0)
        }

        var parameterIndex: Int32 = 1
        if let rangeStartUnix = range.rangeStartUnix {
            statement.bind(double: rangeStartUnix, at: parameterIndex)
            parameterIndex += 1
        }

        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: parameterIndex)
        }

        guard (try? statement.step()) == true else {
            return (nil, 0)
        }

        return (
            averageMilliseconds: statement.isNull(at: 0) ? nil : statement.double(at: 0),
            sampleCount: Int(statement.int64(at: 1))
        )
    }

    func fetchBuckets(
        range: NativAnalyticsRange,
        modelID: String? = nil,
        granularityOverride: NativAnalyticsGranularity? = nil
    ) -> [NativAnalyticsBucketPoint] {
        guard let connection else {
            return []
        }

        let granularity = granularityOverride ?? range.granularity

        let sql = """
            WITH decode_samples AS (
                SELECT
                    model_id,
                    CASE
                        WHEN ? = 'hour' THEN CAST(
                            strftime(
                                '%s',
                                strftime('%Y-%m-%d %H:00:00', completed_at, 'unixepoch', 'localtime'),
                                'utc'
                            ) AS REAL
                        )
                        ELSE CAST(
                            strftime(
                                '%s',
                                date(completed_at, 'unixepoch', 'localtime'),
                                'utc'
                            ) AS REAL
                        )
                    END AS bucket_start,
                    \(decodeSampleTokensSQL) AS decode_tokens,
                    \(decodeSampleMillisecondsSQL) AS decode_elapsed_ms
                FROM request_events
                WHERE status = 'completed'
                \(range.rangeStartUnix == nil ? "" : "AND completed_at >= ?")
                \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            ),
            decode_buckets AS (
                SELECT
                    model_id,
                    bucket_start,
                    SUM(decode_tokens) AS decode_tokens_total,
                    SUM(decode_elapsed_ms) AS decode_elapsed_ms_total
                FROM decode_samples
                WHERE decode_tokens > 0 AND decode_elapsed_ms > 0
                GROUP BY model_id, bucket_start
            )
            SELECT
                buckets.granularity,
                buckets.bucket_start,
                buckets.model_id,
                buckets.requests_started,
                buckets.requests_completed,
                buckets.requests_failed,
                buckets.streaming_requests,
                buckets.prompt_tokens_total,
                buckets.completion_tokens_total,
                buckets.generated_tokens_total,
                buckets.request_elapsed_ms_total,
                COALESCE(decode_buckets.decode_tokens_total, 0),
                COALESCE(decode_buckets.decode_elapsed_ms_total, 0),
                buckets.peak_memory_bytes_max,
                buckets.updated_at
            FROM analytics_buckets AS buckets
            LEFT JOIN decode_buckets
                ON decode_buckets.model_id = buckets.model_id
                AND decode_buckets.bucket_start = buckets.bucket_start
            WHERE buckets.granularity = ?
            \(range.rangeStartUnix == nil ? "" : "AND buckets.bucket_start >= ?")
            \(normalizedModelID(modelID) == nil ? "" : "AND buckets.model_id = ?")
            ORDER BY buckets.bucket_start ASC
            """

        guard let statement = try? connection.prepare(sql) else {
            return []
        }

        statement.bind(text: granularity.rawValue, at: 1)
        var bucketFilterStartIndex: Int32 = 2
        if let rangeStartUnix = range.rangeStartUnix {
            statement.bind(double: rangeStartUnix, at: bucketFilterStartIndex)
            bucketFilterStartIndex += 1
        }
        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: bucketFilterStartIndex)
            bucketFilterStartIndex += 1
        }
        bindBucketFilters(
            statement: statement,
            granularity: granularity,
            rangeStartUnix: range.rangeStartUnix,
            modelID: modelID,
            startingAt: bucketFilterStartIndex
        )

        var rows: [NativAnalyticsBucketPoint] = []
        while (try? statement.step()) == true {
            guard let granularity = NativAnalyticsGranularity(rawValue: statement.string(at: 0) ?? "") else {
                continue
            }

            rows.append(
                NativAnalyticsBucketPoint(
                    granularity: granularity,
                    bucketStart: Date(timeIntervalSince1970: statement.double(at: 1)),
                    modelID: statement.string(at: 2) ?? "Unknown",
                    requestsStarted: Int(statement.int64(at: 3)),
                    requestsCompleted: Int(statement.int64(at: 4)),
                    requestsFailed: Int(statement.int64(at: 5)),
                    streamingRequests: Int(statement.int64(at: 6)),
                    promptTokensTotal: Int(statement.int64(at: 7)),
                    completionTokensTotal: Int(statement.int64(at: 8)),
                    generatedTokensTotal: Int(statement.int64(at: 9)),
                    decodeTokensTotal: Int(statement.int64(at: 11)),
                    requestTimeTotalMilliseconds: statement.int64(at: 10),
                    decodeTimeTotalMilliseconds: statement.int64(at: 12),
                    peakMemoryBytesMax: statement.isNull(at: 13) ? nil : statement.int64(at: 13),
                    updatedAt: statement.isNull(at: 14)
                        ? nil
                        : Date(timeIntervalSince1970: statement.double(at: 14))
                )
            )
        }

        return rows
    }

    func fetchBucketDateBounds(
        granularity: NativAnalyticsGranularity,
        modelID: String? = nil
    ) -> (start: Date, end: Date)? {
        guard let connection else {
            return nil
        }

        let sql = """
            SELECT
                MIN(bucket_start),
                MAX(bucket_start)
            FROM analytics_buckets
            WHERE granularity = ?
            \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            """

        guard let statement = try? connection.prepare(sql) else {
            return nil
        }

        statement.bind(text: granularity.rawValue, at: 1)
        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: 2)
        }

        guard (try? statement.step()) == true,
              !statement.isNull(at: 0),
              !statement.isNull(at: 1)
        else {
            return nil
        }

        return (
            start: Date(timeIntervalSince1970: statement.double(at: 0)),
            end: Date(timeIntervalSince1970: statement.double(at: 1))
        )
    }

    func fetchRecentRequestEvents(
        range: NativAnalyticsRange = .allTime,
        modelID: String? = nil,
        limit: Int = 10
    ) -> [NativAnalyticsRequestEvent] {
        guard let connection else {
            return []
        }

        let sql = """
            SELECT
                request_id,
                completed_at,
                model_id,
                status,
                endpoint,
                streaming,
                prompt_tokens,
                completion_tokens,
                generated_tokens,
                request_elapsed_ms,
                decode_elapsed_ms,
                ttft_ms,
                peak_memory_bytes,
                prefill_tokens_per_second,
                decode_tokens_per_second,
                image_count,
                audio_count,
                structured_output,
                thinking_enabled,
                tool_calls,
                finish_reason,
                backend
            FROM request_events
            WHERE 1 = 1
            \(range.rangeStartUnix == nil ? "" : "AND completed_at >= ?")
            \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            ORDER BY completed_at DESC, created_at DESC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql) else {
            return []
        }

        var parameterIndex: Int32 = 1
        if let rangeStartUnix = range.rangeStartUnix {
            statement.bind(double: rangeStartUnix, at: parameterIndex)
            parameterIndex += 1
        }

        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: parameterIndex)
            parameterIndex += 1
        }

        statement.bind(int64: Int64(limit), at: parameterIndex)

        var rows: [NativAnalyticsRequestEvent] = []
        while (try? statement.step()) == true {
            rows.append(
                NativAnalyticsRequestEvent(
                    requestID: statement.string(at: 0) ?? UUID().uuidString,
                    completedAt: Date(timeIntervalSince1970: statement.double(at: 1)),
                    modelID: statement.string(at: 2) ?? "Unknown",
                    status: statement.string(at: 3) ?? "unknown",
                    endpoint: statement.string(at: 4) ?? "unknown",
                    streaming: statement.int64(at: 5) != 0,
                    promptTokens: Int(statement.int64(at: 6)),
                    completionTokens: Int(statement.int64(at: 7)),
                    generatedTokens: Int(statement.int64(at: 8)),
                    requestElapsedMilliseconds: statement.isNull(at: 9) ? nil : statement.int64(at: 9),
                    decodeElapsedMilliseconds: statement.isNull(at: 10) ? nil : statement.int64(at: 10),
                    ttftMilliseconds: statement.isNull(at: 11) ? nil : statement.int64(at: 11),
                    peakMemoryBytes: statement.isNull(at: 12) ? nil : statement.int64(at: 12),
                    prefillTokensPerSecond: statement.isNull(at: 13) ? nil : statement.double(at: 13),
                    decodeTokensPerSecond: statement.isNull(at: 14) ? nil : statement.double(at: 14),
                    imageCount: Int(statement.int64(at: 15)),
                    audioCount: Int(statement.int64(at: 16)),
                    structuredOutput: statement.int64(at: 17) != 0,
                    thinkingEnabled: statement.int64(at: 18) != 0,
                    toolCalls: statement.int64(at: 19) != 0,
                    finishReason: statement.string(at: 20),
                    backend: statement.string(at: 21)
                )
            )
        }

        return rows
    }

    func fetchTTFTEvents(
        range: NativAnalyticsRange,
        modelID: String? = nil
    ) -> [NativAnalyticsTTFTEvent] {
        guard let connection else {
            return []
        }

        let sql = """
            SELECT completed_at, ttft_ms
            FROM request_events
            WHERE ttft_ms IS NOT NULL
                AND ttft_ms >= 0
            \(range.rangeStartUnix == nil ? "" : "AND completed_at >= ?")
            \(normalizedModelID(modelID) == nil ? "" : "AND model_id = ?")
            ORDER BY completed_at ASC
            """

        guard let statement = try? connection.prepare(sql) else {
            return []
        }

        var parameterIndex: Int32 = 1
        if let rangeStartUnix = range.rangeStartUnix {
            statement.bind(double: rangeStartUnix, at: parameterIndex)
            parameterIndex += 1
        }

        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: parameterIndex)
        }

        var rows: [NativAnalyticsTTFTEvent] = []
        while (try? statement.step()) == true {
            rows.append(
                NativAnalyticsTTFTEvent(
                    completedAt: Date(timeIntervalSince1970: statement.double(at: 0)),
                    milliseconds: statement.int64(at: 1)
                )
            )
        }
        return rows
    }

    func fetchKnownModelIDs() -> [String] {
        guard let connection else {
            return []
        }

        guard let statement = try? connection.prepare(
            """
            SELECT DISTINCT model_id
            FROM request_events
            WHERE status = 'completed'
            ORDER BY model_id COLLATE NOCASE ASC
            """
        ) else {
            return []
        }

        var modelIDs: [String] = []
        while (try? statement.step()) == true {
            if let modelID = statement.string(at: 0), !modelID.isEmpty {
                modelIDs.append(modelID)
            }
        }

        return modelIDs
    }

    private func bindBucketFilters(
        statement: SQLiteStatement,
        granularity: NativAnalyticsGranularity,
        rangeStartUnix: Double?,
        modelID: String?,
        startingAt firstParameterIndex: Int32 = 1
    ) {
        var parameterIndex = firstParameterIndex
        statement.bind(text: granularity.rawValue, at: parameterIndex)
        parameterIndex += 1

        if let rangeStartUnix {
            statement.bind(double: rangeStartUnix, at: parameterIndex)
            parameterIndex += 1
        }

        if let modelID = normalizedModelID(modelID) {
            statement.bind(text: modelID, at: parameterIndex)
        }
    }

    private var decodeSampleTokensSQL: String {
        """
        CASE
            WHEN decode_tokens_per_second > 0 AND generated_tokens > 0
                THEN generated_tokens
            WHEN generated_tokens > 1
                AND ttft_ms IS NOT NULL
                AND request_elapsed_ms > ttft_ms
                THEN generated_tokens - 1
            ELSE 0
        END
        """
    }

    private var decodeSampleMillisecondsSQL: String {
        """
        CASE
            WHEN decode_tokens_per_second > 0 AND generated_tokens > 0
                THEN CAST(ROUND(generated_tokens / decode_tokens_per_second * 1000.0) AS INTEGER)
            WHEN generated_tokens > 1
                AND ttft_ms IS NOT NULL
                AND request_elapsed_ms > ttft_ms
                THEN request_elapsed_ms - ttft_ms
            ELSE 0
        END
        """
    }

    private func normalizedModelID(_ modelID: String?) -> String? {
        guard let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed == "All" ? nil : trimmed
    }
}

private final class SQLiteConnection {
    private let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "Unable to open database"
            sqlite3_close(database)
            throw SQLiteConnectionError.openFailed(message)
        }

        handle = database
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA busy_timeout = 3000;")
        try execute(schemaSQL)
    }

    deinit {
        sqlite3_close(handle)
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(handle: handle, sql: sql)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteConnectionError.executionFailed(message)
        }
    }

    private var message: String {
        guard let rawMessage = sqlite3_errmsg(handle) else {
            return "Unknown SQLite error"
        }
        return String(cString: rawMessage)
    }
}

private final class SQLiteStatement {
    private let handle: OpaquePointer

    init(handle: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = sqlite3_errmsg(handle).map(String.init(cString:)) ?? "Unable to prepare SQLite statement"
            throw SQLiteConnectionError.prepareFailed(message)
        }
        self.handle = statement
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(text: String, at index: Int32) {
        sqlite3_bind_text(handle, index, text, -1, sqliteTransientDestructor)
    }

    func bind(double: Double, at index: Int32) {
        sqlite3_bind_double(handle, index, double)
    }

    func bind(int64: Int64, at index: Int32) {
        sqlite3_bind_int64(handle, index, int64)
    }

    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteConnectionError.stepFailed
        }
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func string(at index: Int32) -> String? {
        guard let rawValue = sqlite3_column_text(handle, index) else {
            return nil
        }
        return String(cString: rawValue)
    }

    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }
}

private enum SQLiteConnectionError: Error {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case stepFailed
}

private let sqliteTransientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private let schemaSQL = """
    CREATE TABLE IF NOT EXISTS request_events (
        request_id TEXT PRIMARY KEY,
        started_at REAL NOT NULL,
        completed_at REAL NOT NULL,
        model_id TEXT NOT NULL,
        endpoint TEXT NOT NULL,
        status TEXT NOT NULL,
        streaming INTEGER NOT NULL,
        prompt_tokens INTEGER NOT NULL,
        completion_tokens INTEGER NOT NULL,
        generated_tokens INTEGER NOT NULL,
        request_elapsed_ms INTEGER,
        decode_elapsed_ms INTEGER,
        ttft_ms INTEGER,
        peak_memory_bytes INTEGER,
        prefill_tokens_per_second REAL,
        decode_tokens_per_second REAL,
        image_count INTEGER NOT NULL,
        audio_count INTEGER NOT NULL,
        structured_output INTEGER NOT NULL,
        thinking_enabled INTEGER NOT NULL,
        tool_calls INTEGER NOT NULL,
        finish_reason TEXT,
        backend TEXT,
        created_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS analytics_buckets (
        granularity TEXT NOT NULL,
        bucket_start REAL NOT NULL,
        model_id TEXT NOT NULL,
        requests_started INTEGER NOT NULL,
        requests_completed INTEGER NOT NULL,
        requests_failed INTEGER NOT NULL,
        streaming_requests INTEGER NOT NULL,
        prompt_tokens_total INTEGER NOT NULL,
        completion_tokens_total INTEGER NOT NULL,
        generated_tokens_total INTEGER NOT NULL,
        request_elapsed_ms_total INTEGER NOT NULL,
        decode_elapsed_ms_total INTEGER NOT NULL,
        peak_memory_bytes_max INTEGER,
        updated_at REAL NOT NULL,
        PRIMARY KEY (granularity, bucket_start, model_id)
    );

    CREATE TABLE IF NOT EXISTS server_sessions (
        session_id TEXT PRIMARY KEY,
        started_at REAL NOT NULL,
        ended_at REAL,
        last_seen_at REAL NOT NULL,
        backend TEXT,
        loaded_model TEXT,
        loaded_adapter TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_request_events_completed_at
        ON request_events (completed_at);
    CREATE INDEX IF NOT EXISTS idx_request_events_model_completed_at
        ON request_events (model_id, completed_at);
    CREATE INDEX IF NOT EXISTS idx_request_events_status_completed_at
        ON request_events (status, completed_at);
    CREATE INDEX IF NOT EXISTS idx_analytics_buckets_granularity_bucket_start
        ON analytics_buckets (granularity, bucket_start);
    CREATE INDEX IF NOT EXISTS idx_analytics_buckets_granularity_model_bucket_start
        ON analytics_buckets (granularity, model_id, bucket_start);
"""
