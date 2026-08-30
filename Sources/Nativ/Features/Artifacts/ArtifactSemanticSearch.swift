import Foundation
import NativServerKit

struct ArtifactSemanticSearchConfig: Sendable {
    let modelID: String
    let sizeBytes: Int64
    let client: NativEmbeddingsClient
    let isModelInstalled: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let canInstall: Bool
    let insufficientReason: String?
    let onEnable: @MainActor @Sendable () -> Void
    var onRemove: @MainActor @Sendable () -> Void = {}
    var prepareModel: @Sendable () -> Void = {}

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
