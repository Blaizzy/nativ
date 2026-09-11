import Foundation
import SQLite3
import XCTest

@MainActor
final class ControlPanelDependencyOwnershipTests: XCTestCase {
    func testApplicationDependenciesAreSharedAcrossControlPanels() {
        let shared = ControlPanelSharedDependencies()
        let first = ControlPanelDependencies(shared: shared)
        let second = ControlPanelDependencies(shared: shared)

        XCTAssertTrue(first.mcpHost === second.mcpHost)
        XCTAssertTrue(first.systemMonitor === second.systemMonitor)
        XCTAssertTrue(first.launchAtLogin === second.launchAtLogin)
        XCTAssertTrue(first.persistedDataChanges === second.persistedDataChanges)
        XCTAssertTrue(first.inferenceActivity === second.inferenceActivity)
        XCTAssertTrue(first.projects === second.projects)
        XCTAssertTrue(first.downloads === second.downloads)
    }

    func testControlPanelsReceiveDistinctWindowIdentifiers() {
        let firstWindowID = UUID()
        let secondWindowID = UUID()

        let first = ControlPanelDependencies(windowID: firstWindowID)
        let second = ControlPanelDependencies(windowID: secondWindowID)

        XCTAssertEqual(first.windowID, firstWindowID)
        XCTAssertEqual(second.windowID, secondWindowID)
    }

    func testControlPanelStateIsIndependent() {
        let shared = ControlPanelSharedDependencies()
        let first = ControlPanelDependencies(shared: shared)
        let second = ControlPanelDependencies(shared: shared)

        XCTAssertFalse(first.chat === second.chat)
        XCTAssertFalse(first.imageGeneration === second.imageGeneration)
        XCTAssertFalse(first.artifacts === second.artifacts)
        XCTAssertFalse(first.dashboard === second.dashboard)
        XCTAssertFalse(first.embeddingLibrary === second.embeddingLibrary)
        XCTAssertFalse(first.routineModelLibrary === second.routineModelLibrary)
    }
}

final class TokenUsageModelPageTests: XCTestCase {
    @MainActor
    func testDashboardLoadsEveryModelForTokenUsageWhileKeepingOtherMetricsGrouped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Analytics.sqlite3")
        _ = NativAnalyticsStore(databaseURL: databaseURL)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let date = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        for index in 0..<17 {
            let sql = """
            INSERT INTO analytics_buckets (
                granularity, bucket_start, model_id, requests_started, requests_completed,
                requests_failed, streaming_requests, prompt_tokens_total, completion_tokens_total,
                generated_tokens_total, request_elapsed_ms_total, decode_elapsed_ms_total, updated_at
            ) VALUES ('hour', \(date), 'org/model-\(index)', 1, 1, 0, 0, \(17 - index), 0, 0, 1000, 1000, \(date));
            """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        let dashboard = DashboardViewModel(analyticsDatabaseURL: databaseURL)
        dashboard.selectedRange = .allTime
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while dashboard.isLoadingHistory, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(dashboard.isLoadingHistory)
        XCTAssertEqual(dashboard.tokenUsageModels.count, 17)
        XCTAssertEqual(dashboard.tokenUsageModels.map(\.totalTokens), Array((1...17).reversed()))
        XCTAssertFalse(dashboard.tokenUsageModels.contains { $0.id == "Other" })
        XCTAssertEqual(Set(dashboard.modelTokenPoints.map(\.modelID)).count, 13)
        XCTAssertTrue(dashboard.modelTokenPoints.contains { $0.modelID == "Other" })
    }

    func testRanksModelsByTotalUsageWithStableTies() {
        let models = TokenUsageModel.grouped([
            point("org/B", tokens: 30), point("org/A", tokens: 10),
            point("org/A", tokens: 20, hour: 1), point("org/C", tokens: 50),
        ])
        XCTAssertEqual(models.map(\.id), ["org/C", "org/A", "org/B"])
        XCTAssertEqual(models.map(\.totalTokens), [50, 30, 30])
        XCTAssertEqual(models[1].points.count, 2)
    }

    func testAll225ModelsAreReachableWithoutAnOtherGroup() {
        let models = fixture(count: 225)
        let pages = (0..<29).map { TokenUsageModelPage(models: models, query: "", index: $0) }
        XCTAssertEqual(pages.flatMap(\.models).map(\.id), models.map(\.id))
        XCTAssertTrue(pages.allSatisfy { $0.models.count <= 8 })
        XCTAssertEqual(pages.first?.rangeLabel, "1–8 of 225")
        XCTAssertEqual(pages.last?.rangeLabel, "225–225 of 225")
        XCTAssertEqual(pages.first?.hasPrevious, false)
        XCTAssertEqual(pages.last?.hasNext, false)
    }

    func testSearchFiltersTheWholeListBeforePaginatingAndPreservesUsageOrder() {
        let models = fixture(count: 40)
        let page = TokenUsageModelPage(models: models, query: "  QWEN/  ", index: 1)
        let matches = models.filter { $0.id.hasPrefix("qwen/") }
        XCTAssertEqual(page.models.map(\.id), Array(matches.dropFirst(8).prefix(8)).map(\.id))
        XCTAssertEqual(page.rangeLabel, "9–16 of 20")
        XCTAssertTrue(page.hasPrevious)
        XCTAssertTrue(page.hasNext)
    }

    func testChartPointsContainExactlyTheCurrentPageModels() {
        let models = fixture(count: 17)
        let page = TokenUsageModelPage(models: models, query: "", index: 1)
        XCTAssertEqual(Set(page.points.map(\.modelID)), Set(page.models.map(\.id)))
        XCTAssertEqual(page.points.reduce(0) { $0 + $1.totalTokens }, page.models.reduce(0) { $0 + $1.totalTokens })
        XCTAssertTrue(Set(page.points.map(\.modelID)).isDisjoint(with: models.prefix(8).map(\.id)))
    }

    func testClampsPagesAfterTheResultSetShrinks() {
        let models = fixture(count: 17)
        let last = TokenUsageModelPage(models: models, query: "", index: 100)
        XCTAssertEqual(last.index, 2)
        XCTAssertEqual(last.models.count, 1)
        XCTAssertFalse(last.hasNext)
        XCTAssertEqual(TokenUsageModelPage(models: models, query: "", index: -1).index, 0)
        XCTAssertEqual(TokenUsageModelPage(models: models, query: "model-16", index: 2).index, 0)
    }

    func testSearchAndPaginationHideForEightOrFewerModels() {
        for count in [0, 1, 8] {
            let page = TokenUsageModelPage(models: fixture(count: count), query: "old search", index: 9)
            XCTAssertFalse(page.showsControls)
            XCTAssertEqual(page.index, 0)
            XCTAssertEqual(page.models.count, count, "A hidden search must not hide models")
        }
    }

    func testSearchControlsRemainAvailableWhenOnlyOneModelMatches() {
        let page = TokenUsageModelPage(models: fixture(count: 40), query: "model-39", index: 0)
        XCTAssertTrue(page.showsControls)
        XCTAssertEqual(page.rangeLabel, "1–1 of 1")
        XCTAssertFalse(page.hasNext)
        XCTAssertFalse(page.hasPrevious)
    }

    func testNoMatchesProducesAnEmptyChartAndDisabledPagination() {
        let page = TokenUsageModelPage(models: fixture(count: 40), query: "missing model", index: 2)
        XCTAssertTrue(page.showsControls)
        XCTAssertTrue(page.points.isEmpty)
        XCTAssertEqual(page.rangeLabel, "0 of 0")
        XCTAssertEqual(page.index, 0)
        XCTAssertFalse(page.hasNext)
        XCTAssertFalse(page.hasPrevious)
    }

    private func fixture(count: Int) -> [TokenUsageModel] {
        TokenUsageModel.grouped((0..<count).map { index in
            point("\(index.isMultiple(of: 2) ? "qwen" : "mlx-community")/model-\(index)", tokens: count - index)
        })
    }

    private func point(_ model: String, tokens: Int, hour: Int = 0) -> DashboardViewModel.ModelTokenPoint {
        .init(modelID: model, bucketStart: Date(timeIntervalSince1970: Double(hour * 3_600)),
              totalTokens: tokens, requestsCompleted: 1, requestsFailed: 0,
              generatedTokensTotal: tokens, decodeTokensTotal: tokens, decodeTimeTotalMilliseconds: 1_000)
    }
}
