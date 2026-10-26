import Foundation

/// The server has one text-model slot. Workers sharing a model may batch;
/// workers requiring a different model wait for those workers to finish.
@MainActor
final class ChatAgentModelGate {
    static let shared = ChatAgentModelGate()

    private struct Occupancy {
        let modelID: String
        var count: Int
    }
    private var occupancy: [URL: Occupancy] = [:]

    func acquire(modelID: String, endpoint: URL) async throws {
        while let current = occupancy[endpoint], current.modelID != modelID {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        if var current = occupancy[endpoint] {
            current.count += 1
            occupancy[endpoint] = current
        } else {
            occupancy[endpoint] = Occupancy(modelID: modelID, count: 1)
        }
    }

    func release(endpoint: URL) {
        guard var current = occupancy[endpoint] else { return }
        current.count -= 1
        occupancy[endpoint] = current.count == 0 ? nil : current
    }
}
