import Foundation

extension LocalModel {
    /// Replaces locally-derived image and tool-calling capabilities with
    /// server-reported truth when the bundled mlx-vlm server reported a
    /// capability set for this model (mlx-vlm is the source of truth).
    /// Matching is by repo id or snapshot path; unknown server id tokens are
    /// ignored and local flags for unrelated capabilities are preserved.
    func overlaying(serverCapabilities: [String: Set<String>]) -> LocalModel {
        guard !serverCapabilities.isEmpty,
              let serverSet = serverCapabilities.first(where: { id, _ in
                  matchesServerID(id)
              })?.value
        else {
            return self
        }
        var caps = capabilities
        caps.remove(.imageGeneration)
        caps.remove(.imageEditing)
        caps.remove(.tools)
        if serverSet.contains("image_generation") {
            caps.insert(.imageGeneration)
        }
        if serverSet.contains("image_editing") {
            caps.insert(.imageEditing)
        }
        if serverSet.contains("tools") {
            caps.insert(.tools)
        }
        return LocalModel(
            repoID: repoID,
            snapshotURL: snapshotURL,
            modifiedAt: modifiedAt,
            sizeBytes: sizeBytes,
            parameterCount: parameterCount,
            quantizationBits: quantizationBits,
            quantizationGroupSize: quantizationGroupSize,
            contextSize: contextSize,
            provider: provider,
            capabilities: caps,
            drafterKind: drafterKind,
            hiddenSize: hiddenSize,
            source: source
        )
    }

    private func matchesServerID(_ id: String) -> Bool {
        if repoID == id || repoID == Self.trimmed(id) {
            return true
        }
        guard let snapshotURL else {
            return false
        }
        let path = snapshotURL.standardizedFileURL.path
        let trimmedID = Self.trimmed(id)
        return path == trimmedID
            || snapshotURL.lastPathComponent == Self.lastComponent(of: trimmedID)
    }

    private static func trimmed(_ id: String) -> String {
        var value = id
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func lastComponent(of id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}
