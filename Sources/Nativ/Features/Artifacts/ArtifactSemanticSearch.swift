import Foundation
import NativServerKit

struct ArtifactSemanticSearchConfig {
    let modelID: String
    let sizeBytes: Int64
    let client: NativEmbeddingsClient
    let isModelInstalled: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let canInstall: Bool
    let insufficientReason: String?
    let onEnable: () -> Void

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
