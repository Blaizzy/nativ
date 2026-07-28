import Foundation
import NativServerKit

enum ChatSystemMonitorToolRegistry {
    static let toolName = "get_system_stats"

    static func definitions() -> [MLXChatToolDefinition] {
        [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Get current CPU, GPU, memory, and disk usage on this Mac.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([:])
            ])
        ))]
    }
}

struct ChatSystemMonitorToolResultPayload: Encodable {
    let ok: Bool
    let cpuUsagePercent: Int?
    let gpuUsagePercent: Int?
    let memoryUsedGB: Double?
    let memoryTotalGB: Double?
    let diskUsedGB: Double?
    let diskTotalGB: Double?
    let uptimeSeconds: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case cpuUsagePercent = "cpu_usage_percent"
        case gpuUsagePercent = "gpu_usage_percent"
        case memoryUsedGB = "memory_used_gb"
        case memoryTotalGB = "memory_total_gb"
        case diskUsedGB = "disk_used_gb"
        case diskTotalGB = "disk_total_gb"
        case uptimeSeconds = "uptime_seconds"
        case error
    }
}

struct ChatSystemMonitorToolExecutor {
    @MainActor
    func execute(
        call: MLXChatToolCall,
        collect: () async throws -> SystemMonitorSnapshot = ChatSystemMonitorToolExecutor.defaultCollect
    ) async throws -> String {
        guard call.function?.name == ChatSystemMonitorToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }

        let snapshot = try await collect()

        let payload = ChatSystemMonitorToolResultPayload(
            ok: true,
            cpuUsagePercent: percent(snapshot.cpu.totalUsage),
            gpuUsagePercent: snapshot.gpu.deviceUsage.flatMap(percent),
            memoryUsedGB: gigabytes(snapshot.memory.usedBytes),
            memoryTotalGB: gigabytes(snapshot.memory.totalBytes),
            diskUsedGB: gigabytes(snapshot.disk.usedBytes),
            diskTotalGB: gigabytes(snapshot.disk.totalBytes),
            uptimeSeconds: Int(snapshot.uptime),
            error: nil
        )
        return try encodedPayload(payload)
    }

    @MainActor
    static func defaultCollect() async throws -> SystemMonitorSnapshot {
        let store = SystemMonitorStore()
        // First read only seeds the previous-tick baseline; second read
        // after a delay gives a real CPU/disk delta.
        _ = await store.collectSnapshot()
        try await Task.sleep(nanoseconds: 300_000_000)
        return await store.collectSnapshot()
    }

    func failurePayload(operation: String, error: Error) -> String {
        let payload = ChatSystemMonitorToolResultPayload(
            ok: false,
            cpuUsagePercent: nil,
            gpuUsagePercent: nil,
            memoryUsedGB: nil,
            memoryTotalGB: nil,
            diskUsedGB: nil,
            diskTotalGB: nil,
            uptimeSeconds: nil,
            error: error.localizedDescription
        )
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"System monitor tool failed."}"#
    }

    private func percent(_ usage: Double) -> Int {
        Int((usage * 100).rounded())
    }

    private func gigabytes(_ bytes: UInt64) -> Double {
        (Double(bytes) / 1_073_741_824 * 100).rounded() / 100
    }

    private func encodedPayload(_ payload: ChatSystemMonitorToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
