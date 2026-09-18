import Foundation
import SQLite3

/// Explicit fields for local hardware diagnostics. Never encode the
/// native identity wholesale: it contains names, serial numbers, volume names and paths.
enum SystemTelemetryProjection {
    static func payload(_ s: SystemMonitorSnapshot) -> [String: Any] {
        var result: [String: Any] = [:]
        func value(_ key: String, _ number: Double?, max: Double = 9_007_199_254_740_991, min: Double = 0) {
            result[key] = number.flatMap { $0.isFinite && $0 >= min && $0 <= max ? $0 : nil }.map { $0 as Any } ?? NSNull()
        }
        // Spell out numeric conversion: Double.init can resolve to init(bitPattern:) for UInt64.
        func bytes(_ key: String, _ number: UInt64?) { value(key, number.map { Double($0) }) }
        func count(_ key: String, _ number: Int?, max: Double = 512) { value(key, number.map(Double.init), max: max) }
        func text(_ key: String, _ string: String, allowed: [String], fallback: String = "unknown") {
            result[key] = allowed.contains(string) ? string : fallback
        }
        let identity = s.identity
        let disk = identity.disk
        let pattern = #"^(Mac|MacBookPro|MacBookAir|Macmini|iMac|MacPro)\d{1,2},\d{1,2}$"#
        result["model_identifier"] = identity.modelIdentifier.range(of: pattern, options: .regularExpression) != nil
            ? identity.modelIdentifier as Any : NSNull()
        // Emit public chip generation/tier, never the original hardware string.
        let chip = identity.chipName.lowercased().split(separator: " ").map(String.init)
        let generation = chip.first(where: { $0.range(of: #"^m\d{1,2}$"#, options: .regularExpression) != nil })
            .flatMap { Int($0.dropFirst()) }
        count("chip_generation", generation, max: 99)
        result["chip_tier"] = generation == nil ? "unknown" : chip.first(where: { ["pro", "max", "ultra"].contains($0) }) ?? "base"
        value("production_year", identity.productionYear.map(Double.init), max: 2100, min: 2000)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        count("os_major", version.majorVersion, max: 100)
        count("os_minor", version.minorVersion, max: 100)
        count("os_patch", version.patchVersion, max: 100)
        count("physical_cores", identity.physicalCoreCount, max: 256)
        count("logical_cores", identity.logicalCoreCount)
        count("efficiency_cores", identity.efficiencyCoreCount, max: 256)
        count("performance_cores", identity.performanceCoreCount, max: 256)
        count("gpu_cores", identity.gpuCoreCount)
        count("ane_cores", identity.aneCoreCount)
        value("cpu_frequency_hz", identity.nominalCPUFrequencyHz.map { Double($0) }, max: 100_000_000_000)
        let resolution = identity.displayResolution.components(separatedBy: " × ")
        count("display_width", resolution.count == 2 ? Int(resolution[0]) : nil, max: 32768)
        count("display_height", resolution.count == 2 ? Int(resolution[1]) : nil, max: 32768)
        value("display_refresh_hz", identity.displayRefreshRate, max: 1000)
        value("uptime_seconds", s.uptime, max: 315360000)
        value("cpu_usage", s.cpu.totalUsage, max: 1)
        value("cpu_user", s.cpu.userUsage, max: 1)
        value("cpu_system", s.cpu.systemUsage, max: 1)
        value("cpu_idle", s.cpu.idleUsage, max: 1)
        result["core_usage"] = s.cpu.coreUsage.prefix(256).map { v -> Any in
            v.isFinite && (0...1).contains(v) ? v : NSNull()
        }
        result["load_averages"] = (0..<3).map { i -> Any in
            guard i < s.cpu.loadAverages.count else { return NSNull() }
            let v = s.cpu.loadAverages[i]
            return v.isFinite && (0...100000).contains(v) ? v : NSNull()
        }
        value("gpu_usage", s.gpu.deviceUsage, max: 1)
        value("ane_usage", s.gpu.aneUsage, max: 1)
        value("display_fps", s.gpu.framesPerSecond, max: 1000)
        bytes("gpu_memory_bytes", s.gpu.allocatedMemoryBytes)
        for (key, amount) in [
            ("memory_total_bytes", s.memory.totalBytes), ("memory_used_bytes", s.memory.usedBytes),
            ("memory_active_bytes", s.memory.activeBytes), ("memory_wired_bytes", s.memory.wiredBytes),
            ("memory_compressed_bytes", s.memory.compressedBytes), ("memory_cached_bytes", s.memory.cachedBytes),
            ("memory_free_bytes", s.memory.freeBytes), ("swap_used_bytes", s.memory.swapUsedBytes),
            ("swap_total_bytes", s.memory.swapTotalBytes)
        ] { bytes(key, s.memory.totalBytes > 0 ? amount : nil) }
        result["memory_pressure"] = s.memory.totalBytes > 0 ? s.memory.pressureLabel.lowercased() : "unknown"
        bytes("disk_total_bytes", s.disk.totalBytes)
        bytes("disk_available_bytes", s.disk.availableBytes)
        value("disk_read_bps", s.disk.readBytesPerSecond, max: 1e13)
        value("disk_write_bps", s.disk.writeBytesPerSecond, max: 1e13)
        bytes("disk_read_bytes", s.disk.cumulativeReadBytes)
        bytes("disk_written_bytes", s.disk.cumulativeWriteBytes)
        let fs = disk.fileSystem.lowercased()
        text("file_system", fs.contains("apfs") ? "apfs" : fs.contains("hfs") ? "hfs" : fs,
             allowed: ["apfs", "hfs", "exfat", "ntfs"], fallback: "other")
        text("disk_connection", disk.connection.lowercased(), allowed: ["internal", "pci", "usb", "thunderbolt", "sata", "nvme"], fallback: "other")
        let storage = disk.model.lowercased()
        result["disk_kind"] = storage.contains("apple ssd") ? "apple_ssd" : storage.contains("ssd") ? "ssd" : storage.contains("hdd") ? "hdd" : "other"
        result["disk_encrypted"] = disk.isEncrypted.map { $0 as Any } ?? NSNull()
        result["disk_writable"] = disk.isWritable.map { $0 as Any } ?? NSNull()
        text("smart_status", disk.smartStatus?.lowercased() ?? "unknown", allowed: ["verified", "failing", "unsupported"])
        count("disk_health_percent", disk.healthPercent, max: 100)
        value("disk_temperature_celsius", disk.temperatureCelsius.map(Double.init), max: 200, min: -50)
        bytes("disk_power_cycles", disk.powerCycles)
        bytes("disk_power_on_hours", disk.powerOnHours)
        bytes("disk_unsafe_shutdowns", disk.unsafeShutdowns)
        bytes("disk_media_errors", disk.mediaErrors)
        count("disk_spare_percent", disk.availableSparePercent, max: 100)
        bytes("disk_lifetime_read_bytes", disk.lifetimeReadBytes)
        bytes("disk_lifetime_written_bytes", disk.lifetimeWrittenBytes)
        value("temperature_celsius", s.thermal.dieTemperatureCelsius, max: 200, min: -50)
        text("thermal_pressure", s.thermal.thermalPressureLabel.lowercased(), allowed: ["nominal", "fair", "serious", "critical"])
        // Stable ordinal labels preserve every sensor reading without exporting raw sensor strings.
        let sensors = s.thermal.sensors.sorted { $0.name < $1.name }.prefix(128)
        var hottestIndex: Int?
        result["sensors"] = sensors.enumerated().compactMap { index, sensor -> [String: Any]? in
            guard sensor.celsius.isFinite, (-50...200).contains(sensor.celsius) else { return nil }
            if sensor.name == s.thermal.hottestSensorName { hottestIndex = index }
            let name = sensor.name.lowercased()
            let kind = sensor.isDieSensor ? "die" : name.contains("cpu") ? "cpu" : name.contains("gpu") ? "gpu"
                : name.contains("battery") ? "battery" : name.contains("nand") ? "storage" : "other"
            return ["index": index, "kind": kind, "celsius": sensor.celsius]
        }
        count("hottest_sensor_index", hottestIndex, max: 127)
        result["fan_rpm"] = s.thermal.fanSpeedsRPM.prefix(16).filter { (0...50000).contains($0) }
        for (key, watts) in [("cpu_watts", s.power.cpuWatts), ("gpu_watts", s.power.gpuWatts),
            ("ane_watts", s.power.aneWatts), ("dram_watts", s.power.dramWatts),
            ("soc_watts", s.power.socWatts), ("system_input_watts", s.power.systemInputWatts)] {
            value(key, watts, max: 10000)
        }
        return result
    }
}

/// Opt-in local hardware history. This recorder performs no networking.
actor SystemTelemetryRecorder {
    /// Reserve room for both the database and SQLite's temporary rollback journal.
    /// A 96 MiB database leaves ample headroom within the 256 MiB storage budget.
    nonisolated static let storageBudgetBytes = 256 * 1024 * 1024
    nonisolated static let minimumFreeBytes: Int64 = 1024 * 1024 * 1024
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Nativ/Diagnostics", isDirectory: true)
    }
    nonisolated static func isEnabled(at directory: URL = defaultDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("system-enabled").path)
    }

    private let directory: URL
    private let databaseByteLimit: Int
    private let availableBytes: @Sendable (URL) -> Int64?
    private var lastAttemptAt: Date?

    init(
        directory: URL = SystemTelemetryRecorder.defaultDirectory,
        storageBudgetBytes: Int = SystemTelemetryRecorder.storageBudgetBytes,
        availableBytes: @escaping @Sendable (URL) -> Int64? = SystemTelemetryRecorder.freeBytes
    ) {
        self.directory = directory
        self.databaseByteLimit = storageBudgetBytes / 8 * 3
        self.availableBytes = availableBytes
    }

    nonisolated static func freeBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    func record(_ snapshot: SystemMonitorSnapshot) throws {
        guard Self.isEnabled(at: directory) else { return }
        if let lastAttemptAt, (0..<60).contains(snapshot.recordedAt.timeIntervalSince(lastAttemptAt)) { return }
        // Throttle failures too, so a full or busy disk does not trigger work every second.
        lastAttemptAt = snapshot.recordedAt
        guard let free = availableBytes(directory), free >= Self.minimumFreeBytes else { return }
        let payload = try JSONSerialization.data(withJSONObject: SystemTelemetryProjection.payload(snapshot), options: [.sortedKeys])
        guard payload.count <= 32 * 1024, let json = String(data: payload, encoding: .utf8) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("SystemTelemetry.sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw Failure.unavailable
        }
        defer { sqlite3_close(database) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(database, 200)
        // DELETE mode avoids an ever-growing WAL when a reader holds an old snapshot.
        // The rollback journal can contain at most the database's original pages.
        try execute(database, """
            PRAGMA journal_mode=DELETE;
            PRAGMA page_size=4096;
            PRAGMA auto_vacuum=INCREMENTAL;
            PRAGMA temp_store=MEMORY;
            PRAGMA cache_spill=OFF;
            """)
        let pageSize = try integer(database, "PRAGMA page_size")
        let maxPages = databaseByteLimit / pageSize
        guard maxPages >= 16,
              try integer(database, "PRAGMA max_page_count=\(maxPages)") <= maxPages else {
            throw Failure.storageLimit
        }
        try execute(database, """
            CREATE TABLE IF NOT EXISTS system_samples (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, sample_id TEXT NOT NULL UNIQUE,
                occurred_at INTEGER NOT NULL, payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS system_samples_time ON system_samples(occurred_at);
            BEGIN IMMEDIATE;
            """)
        var committed = false
        defer { if !committed { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
        // Persist the interval across app restarts as well as within this actor.
        let timestamp = Int(snapshot.recordedAt.timeIntervalSince1970)
        let latest = try integer(database, "SELECT COALESCE(MAX(occurred_at), 0) FROM system_samples")
        if latest > 0, (0..<60).contains(timestamp - latest) { return }
        let cutoff = timestamp - 7 * 86400
        try execute(database, """
            DELETE FROM system_samples WHERE occurred_at < \(cutoff)
                OR seq <= (SELECT COALESCE(MAX(seq), 0) - 10079 FROM system_samples);
            """)
        // Reuse free pages before reaching SQLite's physical page limit. Keep extra
        // space for row/index splits so a large sensor snapshot can replace old rows.
        let neededPages = (payload.count + pageSize - 1) / pageSize + 8
        while try integer(database, "PRAGMA page_count") - integer(database, "PRAGMA freelist_count") + neededPages > maxPages {
            try execute(database, "DELETE FROM system_samples WHERE seq IN (SELECT seq FROM system_samples ORDER BY seq LIMIT 64)")
            guard sqlite3_changes(database) > 0 else { throw Failure.storageLimit }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO system_samples(sample_id, occurred_at, payload) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { throw Failure.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, UUID().uuidString.lowercased(), -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(timestamp))
        sqlite3_bind_text(statement, 3, json, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.unavailable }
        try execute(database, "COMMIT")
        committed = true
        // Return freed pages gradually without a full VACUUM's second database copy.
        try execute(database, "PRAGMA incremental_vacuum(32)")
    }

    private func execute(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    }

    private func integer(_ database: OpaquePointer?, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.unavailable }
        return Int(sqlite3_column_int64(statement, 0))
    }

    enum Failure: Error { case unavailable, storageLimit }
}
