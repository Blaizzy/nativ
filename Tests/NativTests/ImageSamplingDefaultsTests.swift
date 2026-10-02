import XCTest

@testable import NativServerKit

final class ImageSamplingDefaultsTests: XCTestCase {
    func testAutomaticSamplingIsOmittedForGenerationAndEditing() throws {
        let generation = try json(MLXImageGenerationRequest(model: "org/model", prompt: "A lighthouse"))
        let edit = try json(MLXImageEditRequest(model: "org/model", prompt: "At sunset", image: ["/tmp/reference.png"]))

        for request in [generation, edit] {
            XCTAssertNil(request["steps"])
            XCTAssertNil(request["guidance"])
        }
    }

    func testExplicitSamplingOverridesIncludingZeroGuidanceArePreserved() throws {
        let generation = try json(MLXImageGenerationRequest(
            model: "org/model", prompt: "A lighthouse", steps: 50, guidance: 0
        ))
        let edit = try json(MLXImageEditRequest(
            model: "org/model", prompt: "At sunset", image: ["/tmp/reference.png"], steps: 50, guidance: 0
        ))

        for request in [generation, edit] {
            XCTAssertEqual(request["steps"] as? Int, 50)
            XCTAssertEqual(request["guidance"] as? Double, 0)
        }
    }

    func testSamplingFieldsCanBeOverriddenIndependently() throws {
        let generation = try json(MLXImageGenerationRequest(model: "org/model", prompt: "A lighthouse", steps: 12))
        XCTAssertEqual(generation["steps"] as? Int, 12)
        XCTAssertNil(generation["guidance"])

        let edit = try json(MLXImageEditRequest(
            model: "org/model", prompt: "At sunset", image: ["/tmp/reference.png"], guidance: 0
        ))
        XCTAssertNil(edit["steps"])
        XCTAssertEqual(edit["guidance"] as? Double, 0)
    }

    func testDefaultsRequestIncludesModelTaskAndAuthorization() throws {
        let client = NativImageClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!, apiKey: "test_image_token", timeout: 30
        )
        for task in [MLXImageTask.generate, .edit] {
            let model = "/models/My Model + variant & revision?#1"
            let request = try client.makeSamplingDefaultsURLRequest(model: model, task: task)
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(url.path, "/v1/images/defaults")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse(try XCTUnwrap(components.percentEncodedQuery).contains("+"))
            XCTAssertEqual(components.queryItems, [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "task", value: task.rawValue),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test_image_token")
            XCTAssertEqual(request.timeoutInterval, 30)
            XCTAssertNil(request.httpBody)
        }
    }

    func testDefaultsResponseDecodesModelValues() throws {
        let defaults = try JSONDecoder().decode(
            MLXImageSamplingDefaults.self, from: Data(#"{"steps":9,"guidance":0.0}"#.utf8)
        )
        XCTAssertEqual(defaults.steps, 9)
        XCTAssertEqual(defaults.guidance, 0)
    }

    func testNewSettingsPersistAutomaticSampling() throws {
        let settings = ImageRequestSettings()
        XCTAssertNil(settings.steps)
        XCTAssertNil(settings.guidance)
        let decoded = try PropertyListDecoder().decode(
            ImageRequestSettings.self, from: PropertyListEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testSavedNumericSamplingRemainsAnOverride() throws {
        let saved = Data(#"{"count":1,"width":512,"height":512,"steps":4,"guidance":1,"seedText":""}"#.utf8)
        var settings = try JSONDecoder().decode(ImageRequestSettings.self, from: saved)
        XCTAssertEqual(settings.steps, 4)
        XCTAssertEqual(settings.guidance, 1)

        settings.steps = nil
        let restored = try JSONDecoder().decode(ImageRequestSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(restored.steps)
        XCTAssertEqual(restored.guidance, 1)
    }

    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
