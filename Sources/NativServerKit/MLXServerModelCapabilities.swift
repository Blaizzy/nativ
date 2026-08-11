import Foundation

/// Server-reported model capabilities from the bundled mlx-vlm server's
/// `/v1/models` endpoint (additive OpenAI-compatible field).
///
/// mlx-vlm is the source of truth for image capabilities: it computes
/// `image_generation` / `image_editing` per model from its model registry
/// and manifest data. Nativ reads these values and overlays them onto its
/// local scan results; when the server isn't reachable the overlay is
/// skipped and local heuristics remain in effect (unchanged behavior).
public struct MLXServerModelCapabilities: Sendable {
    /// Capability tokens by model identifier (repo id or local snapshot path),
    /// exactly as reported by the server.
    public let byModelID: [String: Set<String>]

    public init(byModelID: [String: Set<String>]) {
        self.byModelID = byModelID
    }

    /// Fetches the server's model capability map. Never throws: any failure
    /// (server down, bad response, timeout) yields an empty map so callers
    /// can degrade to local heuristics without error handling.
    public static func fetch(baseURL: URL) async -> MLXServerModelCapabilities {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/models"),
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let payload = try? JSONDecoder().decode(Response.self, from: data)
        else {
            return MLXServerModelCapabilities(byModelID: [:])
        }
        var byModelID: [String: Set<String>] = [:]
        byModelID.reserveCapacity(payload.data.count)
        for model in payload.data {
            guard !model.id.isEmpty else { continue }
            byModelID[model.id] = Set(model.capabilities ?? [])
        }
        return MLXServerModelCapabilities(byModelID: byModelID)
    }
}

extension MLXServerModelCapabilities {
    private struct Response: Decodable {
        let data: [ModelInfo]
    }

    private struct ModelInfo: Decodable {
        let id: String
        let capabilities: [String]?
    }
}