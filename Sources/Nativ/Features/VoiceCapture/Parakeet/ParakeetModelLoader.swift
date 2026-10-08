import CoreAI
import Foundation

@available(macOS 27.0, *)
enum ParakeetModelLoader {
    static func load(from directory: URL, sourceName: String) async throws -> AIModel {
        let url = directory.appendingPathComponent(sourceName)
        var options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        // The encoder and decoder are exported with fixed shapes.
        options.expectFrequentReshapes = false
        do {
            if let cached = try AIModelCache.default.model(for: url, options: options) {
                NSLog("Nativ loaded cached Parakeet specialization: %@", url.lastPathComponent)
                return cached
            }
        } catch {
            NSLog("Nativ could not read Parakeet specialization cache: %@", error.localizedDescription)
        }
        try Task.checkCancellation()
        NSLog("Nativ specializing Parakeet: %@", url.lastPathComponent)
        // CoreAI owns cache invalidation on OS/model changes and storage pressure.
        // Retain the source asset rather than persisting bookmarks to deleted files.
        return try await AIModel.specialize(contentsOf: url, options: options)
    }
}
