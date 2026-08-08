import XCTest
@testable import nativ

final class NativConfigTests: XCTestCase {

    private func config(default d: String?, embedding e: String? = nil, image i: String? = nil, stt s: String? = nil) -> NativConfig {
        NativConfig(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: nil, defaultModel: d,
            embeddingModel: e, imageModel: i, sttModel: s,
            modelSearchPath: nil
        )
    }

    func testCapabilityModelsFallBackToDefault() {
        let c = config(default: "chat-model")
        XCTAssertEqual(c.resolvedEmbeddingModel, "chat-model")
        XCTAssertEqual(c.resolvedImageModel, "chat-model")
        XCTAssertEqual(c.resolvedSTTModel, "chat-model")
    }

    func testCapabilityModelsPreferTheirOwn() {
        let c = config(default: "chat-model", embedding: "embed-model", image: "img-model", stt: "stt-model")
        XCTAssertEqual(c.resolvedEmbeddingModel, "embed-model")
        XCTAssertEqual(c.resolvedImageModel, "img-model")
        XCTAssertEqual(c.resolvedSTTModel, "stt-model")
    }

    func testCapabilityModelsNilWhenNothingSet() {
        let c = config(default: nil)
        XCTAssertNil(c.resolvedEmbeddingModel)
        XCTAssertNil(c.resolvedImageModel)
        XCTAssertNil(c.resolvedSTTModel)
    }

    func testFileConfigRoundTrips() throws {
        let file = NativConfig.FileConfig(
            baseURL: "http://host:9000", apiKey: "k", defaultModel: "m",
            embeddingModel: "e", imageModel: "i", sttModel: "s", modelSearchPath: "/models"
        )
        let data = try JSONEncoder().encode(file)
        let back = try JSONDecoder().decode(NativConfig.FileConfig.self, from: data)
        XCTAssertEqual(back.baseURL, "http://host:9000")
        XCTAssertEqual(back.embeddingModel, "e")
        XCTAssertEqual(back.modelSearchPath, "/models")
    }
}
