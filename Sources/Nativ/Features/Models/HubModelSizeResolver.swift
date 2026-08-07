import Foundation

@MainActor
final class HubModelSizeResolver: ObservableObject {
    static let shared = HubModelSizeResolver()

    @Published private(set) var sizes: [String: Int64] = [:]
    private var inFlight: Set<String> = []

    func resolvedSize(for repoID: String) -> Int64? {
        sizes[repoID]
    }

    func prefetch(_ repoID: String) async {
        if sizes[repoID] != nil || inFlight.contains(repoID) {
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled || sizes[repoID] != nil || inFlight.contains(repoID) {
            return
        }
        inFlight.insert(repoID)
        Task {
            let bytes = await Self.fetchTotalBytes(repoID: repoID)
            inFlight.remove(repoID)
            if let bytes {
                sizes[repoID] = bytes
            }
        }
    }

    private nonisolated static func fetchTotalBytes(repoID: String) async -> Int64? {
        guard let encoded = repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true")
        else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(SizePayload.self, from: data) else {
            return nil
        }
        let total = payload.siblings?.reduce(Int64(0)) { partial, sibling in
            partial + (sibling.lfs?.size ?? sibling.size ?? 0)
        } ?? 0
        return total > 0 ? total : nil
    }

    private struct SizePayload: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable {
                let size: Int64?
            }
            let size: Int64?
            let lfs: LFS?
        }
        let siblings: [Sibling]?
    }
}
