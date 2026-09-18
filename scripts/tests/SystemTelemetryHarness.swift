import Foundation
import SQLite3

// The production collector's only UI-formatting dependencies, for this isolated native test.
enum NativFormatting { static let missingValue = "—" }

@main
struct SystemTelemetryHarness {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("fresh-history")
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        precondition(SystemTelemetryRecorder.freeBytes(at: directory) != nil, "Missing history directory blocked the first write")
        precondition(!FileManager.default.fileExists(atPath: directory.path), "Free-space probe created history")
        precondition(SystemTelemetryRecorder.storageBudgetBytes == 1_000_000_000, "Default storage budget must be 1 GB")
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max })
        var s = SystemMonitorSnapshot()
        s.recordedAt = Date().addingTimeInterval(-120)
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
        let payload = SystemTelemetryProjection.payload(s)
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: encoded, as: UTF8.self)
        precondition(!text.contains("PRIVATE") && !text.contains("/private"), "Native projection leaked identity")
        precondition(payload["cpu_usage"] as? Double == 0.4)
        precondition(payload["ane_usage"] is NSNull)
        precondition(payload["chip_generation"] as? Double == 5)
        precondition(payload["memory_total_bytes"] as? Double == 68_719_476_736)
        precondition(payload["cpu_frequency_hz"] as? Double == 4_000_000_000)
        precondition(payload["disk_power_cycles"] as? Double == 180)
        precondition((payload["core_usage"] as? [Any])?[2] is NSNull)
        try await recorder.record(s)
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SystemTelemetry.sqlite3").path), "Automatic recording did not create history")
        s.recordedAt = s.recordedAt.addingTimeInterval(10)
        try await recorder.record(s) // Throttled.
        try await SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max }).record(s) // Restart is throttled too.
        s.recordedAt = s.recordedAt.addingTimeInterval(50)
        try await recorder.record(s)
        var db: OpaquePointer?
        precondition(sqlite3_open_v2(directory.appendingPathComponent("SystemTelemetry.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM system_samples", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        precondition(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 2, "Recorder throttle failed")
        try await verifyRetention(directory.appendingPathComponent("retention"))
        try await verifyStorageBudget(directory.appendingPathComponent("budget"))
        try await verifyLowSpace(directory.appendingPathComponent("low-space"))
        var policy = SystemMonitorObservationPolicy()
        let ui = UUID(), telemetry = UUID()
        precondition(policy.begin(telemetry), "History did not start without a UI observer")
        precondition(!policy.begin(telemetry), "Repeated startup created another sampling loop")
        precondition(!policy.begin(ui) && !policy.end(ui), "Closing the tab stopped automatic history")
        precondition(policy.pause(), "Automatic history did not pause")
        precondition(!policy.begin(telemetry), "History startup overrode an explicit pause")
        precondition(policy.resume(), "Automatic history did not resume")
        print("Native projection, automatic startup, throttle, pause and bounded retention passed.")
    }

    static func verifyRetention(_ directory: URL) async throws {
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in Int64.max })
        var sample = SystemMonitorSnapshot()
        sample.recordedAt = Date().addingTimeInterval(-8 * 86400)
        try await recorder.record(sample)
        sample.recordedAt = Date()
        try await recorder.record(sample)
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("SystemTelemetry.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func count() -> Int32 {
            var query: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM system_samples", -1, &query, nil) == SQLITE_OK)
            defer { sqlite3_finalize(query) }
            precondition(sqlite3_step(query) == SQLITE_ROW)
            return sqlite3_column_int(query, 0)
        }
        precondition(count() == 1, "Expired local samples were retained")
        precondition(sqlite3_exec(db, """
            WITH RECURSIVE samples(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM samples WHERE n < 10080)
            INSERT INTO system_samples(sample_id, occurred_at, payload)
            SELECT 'synthetic-' || n, \(Int(sample.recordedAt.timeIntervalSince1970)), '{}' FROM samples;
            """, nil, nil, nil) == SQLITE_OK)
        sample.recordedAt = sample.recordedAt.addingTimeInterval(60)
        try await recorder.record(sample)
        precondition(count() == 10080, "Local sample count exceeded the bound")
    }
    static func verifyStorageBudget(_ directory: URL) async throws {
        // Exercise the actual page cap quickly using the same policy with a small budget.
        let budget = 512 * 1024
        let recorder = SystemTelemetryRecorder(directory: directory, storageBudgetBytes: budget, availableBytes: { _ in Int64.max })
        var sample = SystemMonitorSnapshot()
        sample.cpu.coreUsage = Array(repeating: 0.123456789, count: 256)
        sample.thermal.sensors = (0..<128).map { .init(name: "CPU-\($0)", celsius: Double($0)) }
        sample.recordedAt = Date()
        let firstTime = Int(sample.recordedAt.timeIntervalSince1970)
        var peakSize = 0
        for _ in 0..<160 {
            try await recorder.record(sample)
            sample.recordedAt = sample.recordedAt.addingTimeInterval(60)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let size = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            peakSize = max(peakSize, size)
            precondition(size < budget, "Recorder exceeded its storage budget")
        }
        let url = directory.appendingPathComponent("SystemTelemetry.sqlite3")
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*), MIN(occurred_at), MAX(occurred_at) FROM system_samples", -1, &query, nil) == SQLITE_OK)
        precondition(sqlite3_step(query) == SQLITE_ROW)
        precondition(sqlite3_column_int(query, 0) > 0 && sqlite3_column_int(query, 0) < 160, "Byte cap did not prune old snapshots")
        precondition(sqlite3_column_int64(query, 1) > firstTime, "Oldest snapshots were not evicted")
        precondition(sqlite3_column_int64(query, 2) == firstTime + 159 * 60, "New snapshots stopped replacing old history")
        sqlite3_finalize(query)
        precondition(peakSize <= budget / 8 * 3, "Database exceeded its page budget")
        precondition(!FileManager.default.fileExists(atPath: url.path + "-wal"), "A WAL can grow behind a long-lived reader")

        // Holding a reader must fail promptly and leave the previous history intact.
        precondition(sqlite3_exec(db, "BEGIN; SELECT * FROM system_samples", nil, nil, nil) == SQLITE_OK)
        do {
            try await recorder.record(sample)
            preconditionFailure("A locked reader unexpectedly allowed a commit")
        } catch SystemTelemetryRecorder.Failure.unavailable {}
        precondition(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        sample.recordedAt = sample.recordedAt.addingTimeInterval(60)
        try await recorder.record(sample)
        precondition(sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &query, nil) == SQLITE_OK)
        defer { sqlite3_finalize(query) }
        precondition(sqlite3_step(query) == SQLITE_ROW && String(cString: sqlite3_column_text(query, 0)) == "ok")
        print("Storage budget: peak database \(peakSize) bytes within \(budget) bytes; eviction and locked-reader recovery passed.")
    }

    static func verifyLowSpace(_ directory: URL) async throws {
        let recorder = SystemTelemetryRecorder(directory: directory, availableBytes: { _ in SystemTelemetryRecorder.minimumFreeBytes - 1 })
        try await recorder.record(SystemMonitorSnapshot())
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("SystemTelemetry.sqlite3").path), "Low disk space must skip writes")
    }

}
