import Foundation
import XCTest

final class HuggingFaceCuratedModelLoaderTests: XCTestCase {
    func testBoundsFetchConcurrencyAndPreservesSuccessfulModelOrder() async throws {
        let ids = (0..<12).map { "org/model-\($0)-9B-4bit" }
        let missingID = ids[4]
        let invalidID = ids[8]
        var preparedPayloads = try Dictionary(
            uniqueKeysWithValues: ids.map { ($0, try modelData(id: $0)) }
        )
        preparedPayloads[missingID] = nil
        preparedPayloads[invalidID] = Data("not-json".utf8)
        let payloads = preparedPayloads
        let probe = CuratedFetchProbe(payloads: payloads)
        let loader = HuggingFaceCuratedModelLoader(maximumConcurrentRequests: 3) { id in
            await probe.fetch(id: id)
        }

        let models = await loader.load(ids: ids)
        let maximumConcurrency = await probe.maximumConcurrency

        XCTAssertEqual(
            models.map(\.id),
            ids.filter { $0 != missingID && $0 != invalidID }
        )
        XCTAssertEqual(maximumConcurrency, 3)
    }

    func testRepeatedCuratedModelDecodingIsStable() async throws {
        let ids = (0..<12).map { "org/model-\($0)-9B-4bit" }
        let payloads = try Dictionary(
            uniqueKeysWithValues: ids.map { ($0, try modelData(id: $0)) }
        )
        let loader = HuggingFaceCuratedModelLoader { id in
            payloads[id]
        }

        for _ in 0..<50 {
            let models = await loader.load(ids: ids)
            XCTAssertEqual(models.map(\.id), ids)
        }
    }

    private func modelData(id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id,
            "downloads": 100,
            "likes": 10,
            "pipeline_tag": "text-generation",
            "library_name": "mlx",
            "tags": ["text-generation"],
            "private": false,
            "gated": false,
            "safetensors": [
                "parameters": ["F16": 2_000_000]
            ]
        ])
    }
}

private actor CuratedFetchProbe {
    private let payloads: [String: Data]
    private var activeFetches = 0
    private(set) var maximumConcurrency = 0

    init(payloads: [String: Data]) {
        self.payloads = payloads
    }

    func fetch(id: String) async -> Data? {
        activeFetches += 1
        maximumConcurrency = max(maximumConcurrency, activeFetches)
        defer { activeFetches -= 1 }

        let delayBucket = id.utf8.reduce(0) { $0 + Int($1) } % 4 + 1
        let delay = UInt64(delayBucket) * 2_000_000
        do {
            try await Task.sleep(nanoseconds: delay)
        } catch {
            return nil
        }
        return payloads[id]
    }
}
