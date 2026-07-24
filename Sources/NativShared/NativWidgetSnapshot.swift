import Darwin
import Foundation

struct NativWidgetSnapshot: Codable, Equatable {
    var updatedAt = Date()
    var session = NativWidgetSessionSnapshot()
    var system = NativWidgetSystemSnapshot()

    static let placeholder = NativWidgetSnapshot(
        session: NativWidgetSessionSnapshot(
            isRunning: true,
            status: "Running",
            modelName: "Nativ Model",
            processedTokens: 12_480,
            promptTokens: 4_210,
            generatedTokens: 8_270,
            averageDecodeTokensPerSecond: 42.6,
            completedRequests: 38,
            failedRequests: 1,
            inFlightRequests: 0,
            uptimeSeconds: 7_420,
            tokenActivity: [
                NativWidgetTokenActivitySample(
                    recordedAt: Date().addingTimeInterval(-160),
                    promptTokens: 420,
                    generatedTokens: 180
                ),
                NativWidgetTokenActivitySample(
                    recordedAt: Date().addingTimeInterval(-120),
                    promptTokens: 150,
                    generatedTokens: 510
                ),
                NativWidgetTokenActivitySample(
                    recordedAt: Date().addingTimeInterval(-80),
                    promptTokens: 720,
                    generatedTokens: 340
                ),
                NativWidgetTokenActivitySample(
                    recordedAt: Date().addingTimeInterval(-40),
                    promptTokens: 280,
                    generatedTokens: 860
                ),
            ]
        ),
        system: NativWidgetSystemSnapshot(
            cpuUsage: 0.28,
            gpuUsage: 0.44,
            memoryUsage: 0.48,
            usedMemoryBytes: 46 * 1024 * 1024 * 1024,
            totalMemoryBytes: 96 * 1024 * 1024 * 1024,
            cpuHistory: [0.18, 0.24, 0.21, 0.31, 0.26, 0.28],
            gpuHistory: [0.34, 0.38, 0.41, 0.39, 0.45, 0.44],
            memoryHistory: [0.45, 0.46, 0.46, 0.47, 0.48, 0.48]
        )
    )
}

struct NativWidgetSessionSnapshot: Codable, Equatable {
    var isRunning = false
    var status = "Server Off"
    var modelName = "No model loaded"
    var processedTokens = 0
    var promptTokens = 0
    var generatedTokens = 0
    var averageDecodeTokensPerSecond = 0.0
    var completedRequests = 0
    var failedRequests = 0
    var inFlightRequests = 0
    var uptimeSeconds = 0.0
    var tokenActivity: [NativWidgetTokenActivitySample] = []
}

struct NativWidgetTokenActivitySample: Codable, Equatable {
    var recordedAt = Date()
    var promptTokens = 0
    var generatedTokens = 0

    var totalTokens: Int {
        promptTokens + generatedTokens
    }
}

struct NativWidgetSystemSnapshot: Codable, Equatable {
    var cpuUsage = 0.0
    var gpuUsage: Double?
    var memoryUsage = 0.0
    var usedMemoryBytes: UInt64 = 0
    var totalMemoryBytes: UInt64 = 0
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memoryHistory: [Double] = []
}

enum NativWidgetSnapshotStore {
    private static let snapshotFilename = "NativWidgetSnapshot.json"

    static func load() -> NativWidgetSnapshot {
        guard let data = try? Data(contentsOf: snapshotFileURL),
              let snapshot = try? JSONDecoder().decode(
                  NativWidgetSnapshot.self,
                  from: data
              ) else {
            return NativWidgetSnapshot()
        }
        return snapshot
    }

    static func save(_ snapshot: NativWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: sharedContainerURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: snapshotFileURL, options: .atomic)
    }

    private static var snapshotFileURL: URL {
        sharedContainerURL.appendingPathComponent(snapshotFilename)
    }

    private static var sharedContainerURL: URL {
        return userHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(
                "io.github.blaizzy.nativ",
                isDirectory: true
            )
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    private static var userHomeDirectory: URL {
        if let passwordEntry = getpwuid(getuid()),
           let homeDirectory = passwordEntry.pointee.pw_dir {
            return URL(
                fileURLWithPath: String(cString: homeDirectory),
                isDirectory: true
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
