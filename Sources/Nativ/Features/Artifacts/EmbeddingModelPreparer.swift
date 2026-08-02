import Foundation

// Some community embedding checkpoints declare a base generative `model_type`
// in their config.json (e.g. "qwen3_vl") even though the weights are an
// embedding model. mlx-vlm would then load them through the generative class,
// which does not produce pooled embeddings. Before the embedding server reads a
// downloaded model, rewrite its local config.json to the matching embedding
// `model_type` so it loads the embedding class. This keeps the model-specific
// mapping on our side rather than in mlx-vlm.
enum EmbeddingModelPreparer {
    // Base generative model_type -> the embedding class mlx-vlm should load.
    private static let embeddingModelTypes: [String: String] = [
        "qwen3_vl": "qwen3_vl_embedding"
    ]

    static func prepare(repoID: String, searchPath: String) {
        guard let configURL = configURL(repoID: repoID, searchPath: searchPath),
              let data = try? Data(contentsOf: configURL),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let modelType = object["model_type"] as? String,
              let embeddingType = embeddingModelTypes[modelType]
        else {
            return
        }
        object["model_type"] = embeddingType
        guard let updated = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }
        try? updated.write(to: configURL, options: .atomic)
    }

    private static func configURL(repoID: String, searchPath: String) -> URL? {
        let root = URL(
            fileURLWithPath: (searchPath as NSString).expandingTildeInPath,
            isDirectory: true
        )
        let repoDirectory = root.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshots = repoDirectory.appendingPathComponent("snapshots")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let newest = entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lhsDate < rhsDate
            }
        return newest?.appendingPathComponent("config.json")
    }
}
