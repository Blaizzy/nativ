import Foundation
import SQLite3
import XCTest

@MainActor
final class SystemTelemetryTests: XCTestCase {
    func testProjectionPreservesMeasurementsAndOmitsPrivateFields() throws {
        let payload = SystemTelemetryProjection.payload(sample())
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("/private"))
        XCTAssertEqual(payload["model_identifier"] as? String, "Mac17,6")
        XCTAssertEqual(payload["cpu_usage"] as? Double, 0.4)
        XCTAssertEqual(payload["gpu_usage"] as? Double, 0.6)
        XCTAssertTrue(payload["ane_usage"] is NSNull)
        XCTAssertEqual(payload["chip_generation"] as? Double, 5)
        XCTAssertEqual(payload["memory_total_bytes"] as? Double, 68_719_476_736)
        XCTAssertEqual(payload["memory_used_bytes"] as? Double, 34_359_738_368)
        XCTAssertEqual(payload["swap_used_bytes"] as? Double, 2_147_483_648)
        XCTAssertEqual(payload["disk_total_bytes"] as? Double, 1_099_511_627_776)
        XCTAssertEqual(payload["disk_available_bytes"] as? Double, 549_755_813_888)
        XCTAssertEqual(payload["disk_health_percent"] as? Double, 97)
        XCTAssertEqual(payload["cpu_frequency_hz"] as? Double, 4_000_000_000)
        XCTAssertEqual(payload["disk_power_cycles"] as? Double, 180)
        XCTAssertTrue((payload["core_usage"] as? [Any])?[2] is NSNull)
    }

    func testCreatesHistoryAutomaticallyAndThrottlesAcrossRestarts() async throws {
        let directory = temporaryDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNotNil(SystemTelemetryRecorder.freeBytes(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(SystemTelemetryRecorder.storageBudgetBytes, 1_000_000_000)
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max })
        var snapshot = sample()

        try await recorder.record(snapshot)
        let databaseURL = directory.appendingPathComponent("SystemTelemetry.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        snapshot.recordedAt.addTimeInterval(10)
        try await recorder.record(snapshot)
        let restarted = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max })
        try await restarted.record(snapshot)
        snapshot.recordedAt.addTimeInterval(50)
        try await recorder.record(snapshot)

        let database = try openDatabase(directory)
        defer { sqlite3_close(database) }
        XCTAssertEqual(try integer(database, "SELECT COUNT(*) FROM system_samples"), 2)
        let saved = try scalar(database, "SELECT payload FROM system_samples ORDER BY seq LIMIT 1")
        XCTAssertFalse(saved.contains("PRIVATE"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        XCTAssertEqual(payload["cpu_usage"] as? Double, 0.4)
        XCTAssertEqual(payload["memory_total_bytes"] as? Double, 68_719_476_736)
    }

    func testKeepsOldHistoryAndMoreThanTenThousandRowsBelowBudget() async throws {
        let directory = temporaryDirectory()
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max })
        var snapshot = sample()
        try await recorder.record(snapshot)
        snapshot.recordedAt.addTimeInterval(8 * 86400)
        try await recorder.record(snapshot)

        let database = try openDatabase(directory)
        defer { sqlite3_close(database) }
        XCTAssertEqual(try integer(database, "SELECT COUNT(*) FROM system_samples"), 2)
        try execute(database, """
            WITH RECURSIVE samples(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM samples WHERE n < 10080)
            INSERT INTO system_samples(sample_id, occurred_at, payload)
            SELECT 'synthetic-' || n, \(Int(snapshot.recordedAt.timeIntervalSince1970)), '{}' FROM samples;
            """)
        snapshot.recordedAt.addTimeInterval(60)
        try await recorder.record(snapshot)
        XCTAssertEqual(try integer(database, "SELECT COUNT(*) FROM system_samples"), 10083)
    }

    func testEvictsOldestHistoryOnlyWhenStorageFills() async throws {
        let directory = temporaryDirectory()
        let budget = 512 * 1024
        let recorder = SystemTelemetryRecorder(directory: directory, storageBudgetBytes: budget, availableBytes: { _ in Int64.max })
        var snapshot = sample()
        snapshot.cpu.coreUsage = Array(repeating: 0.123456789, count: 256)
        snapshot.thermal.sensors = (0..<128).map { .init(name: "CPU-\($0)", celsius: Double($0)) }
        let firstTime = Int(snapshot.recordedAt.timeIntervalSince1970)
        let url = directory.appendingPathComponent("SystemTelemetry.sqlite3")
        var peakSize = 0

        for _ in 0..<160 {
            try await recorder.record(snapshot)
            snapshot.recordedAt.addTimeInterval(60)
            let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            peakSize = max(peakSize, size)
            XCTAssertLessThanOrEqual(size, budget)
        }

        let database = try openDatabase(directory)
        defer { sqlite3_close(database) }
        let count = try integer(database, "SELECT COUNT(*) FROM system_samples")
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 160)
        XCTAssertGreaterThan(try integer(database, "SELECT MIN(occurred_at) FROM system_samples"), firstTime)
        XCTAssertEqual(try integer(database, "SELECT MAX(occurred_at) FROM system_samples"), firstTime + 159 * 60)
        XCTAssertGreaterThan(peakSize, budget * 9 / 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    func testRecoversAfterReaderBlocksCommit() async throws {
        let directory = temporaryDirectory()
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max })
        var snapshot = sample()
        try await recorder.record(snapshot)
        let database = try openDatabase(directory)
        defer { sqlite3_close(database) }
        try execute(database, "BEGIN; SELECT * FROM system_samples")
        snapshot.recordedAt.addTimeInterval(60)

        do {
            try await recorder.record(snapshot)
            XCTFail("A locked reader unexpectedly allowed a commit")
        } catch SystemTelemetryRecorder.Failure.unavailable {}
        try execute(database, "ROLLBACK")
        XCTAssertEqual(try integer(database, "SELECT COUNT(*) FROM system_samples"), 1)

        snapshot.recordedAt.addTimeInterval(60)
        try await recorder.record(snapshot)
        XCTAssertEqual(try integer(database, "SELECT COUNT(*) FROM system_samples"), 2)
        XCTAssertEqual(try integer(database, "SELECT MAX(occurred_at) FROM system_samples"), Int(snapshot.recordedAt.timeIntervalSince1970))
        XCTAssertEqual(try scalar(database, "PRAGMA integrity_check"), "ok")
    }

    func testSkipsWritesWhenDiskSpaceIsLow() async throws {
        let directory = temporaryDirectory()
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in SystemTelemetryRecorder.minimumFreeBytes - 1 })
        try await recorder.record(sample())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SystemTelemetry.sqlite3").path))
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func openDatabase(_ directory: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let url = directory.appendingPathComponent("SystemTelemetry.sqlite3")
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK else {
            sqlite3_close(database)
            throw databaseError(result)
        }
        return try XCTUnwrap(database)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw databaseError(result) }
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw databaseError(result) }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { throw databaseError(step) }
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    private func integer(_ database: OpaquePointer, _ sql: String) throws -> Int {
        try XCTUnwrap(Int(scalar(database, sql)))
    }

    private func databaseError(_ code: Int32) -> NSError {
        NSError(domain: "SystemTelemetryTests.SQLite", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errstr(code))
        ])
    }

    private func sample() -> SystemMonitorSnapshot {
        var s = SystemMonitorSnapshot()
        s.recordedAt = Date(timeIntervalSince1970: 1_750_000_000)
        s.identity.computerName = "PRIVATE-COMPUTER"
        s.identity.serialNumber = "PRIVATE-SERIAL"
        s.identity.modelNumber = "PRIVATE-SKU"
        s.identity.modelIdentifier = "Mac17,6"
        s.identity.chipName = "Apple M5 Max"
        s.identity.physicalCoreCount = 16
        s.identity.logicalCoreCount = 16
        s.identity.efficiencyCoreCount = 4
        s.identity.performanceCoreCount = 12
        s.identity.gpuCoreCount = 40
        s.identity.aneCoreCount = 16
        s.identity.nominalCPUFrequencyHz = 4_000_000_000
        s.identity.displayName = "PRIVATE-DISPLAY"
        s.identity.displayResolution = "3456 × 2234"
        s.identity.displayRefreshRate = 120
        s.identity.disk.volumeName = "PRIVATE-VOLUME"
        s.identity.disk.mountPoint = "/private/path"
        s.identity.disk.deviceIdentifier = "PRIVATE-DISK"
        s.identity.disk.model = "APPLE SSD PRIVATE-DISK-MODEL"
        s.identity.disk.smartStatus = "Verified"
        s.identity.disk.healthPercent = 97
        s.identity.disk.mediaErrors = 0
        s.identity.disk.powerCycles = 180
        s.identity.disk.availableSparePercent = 100
        s.identity.disk.temperatureCelsius = 39
        s.cpu.totalUsage = 0.4
        s.cpu.userUsage = 0.3
        s.cpu.systemUsage = 0.1
        s.cpu.idleUsage = 0.6
        s.cpu.coreUsage = [0.2, 0.7, .nan]
        s.cpu.loadAverages = [1.2, 2.3, 3.4]
        s.gpu.deviceUsage = 0.6
        s.gpu.aneUsage = nil
        s.gpu.framesPerSecond = 119.5
        s.memory.totalBytes = 64 * 1024 * 1024 * 1024
        s.memory.usedBytes = 32 * 1024 * 1024 * 1024
        s.memory.swapUsedBytes = 2 * 1024 * 1024 * 1024
        s.disk.totalBytes = 1024 * 1024 * 1024 * 1024
        s.disk.availableBytes = 512 * 1024 * 1024 * 1024
        s.disk.readBytesPerSecond = 1024 * 1024
        s.thermal.sensors = [.init(name: "PRIVATE-tdie", celsius: 65), .init(name: "PRIVATE-battery", celsius: 32)]
        s.thermal.hottestSensorName = "PRIVATE-tdie"
        s.thermal.dieTemperatureCelsius = 65
        s.thermal.fanSpeedsRPM = [2200, 2300]
        s.power.cpuWatts = 12
        s.power.gpuWatts = 20
        s.power.socWatts = 36
        return s
    }
}
