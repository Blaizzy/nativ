import Foundation
import NativServerKit
import XCTest

final class MLXServerModelCapabilitiesTests: XCTestCase {
    private var didRegisterProtocol = false

    override func setUp() {
        super.setUp()
        didRegisterProtocol = URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        if didRegisterProtocol {
            URLProtocol.unregisterClass(MockURLProtocol.self)
        }
        MockURLProtocol.responseHandler = nil
        super.tearDown()
    }

    private func stubModelsResponse(_ json: String, statusCode: Int = 200) {
        MockURLProtocol.responseHandler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8080/v1/models")!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }
    }

    func testFetchDecodesCapabilitiesByID() async {
        stubModelsResponse("""
        {
          "object": "list",
          "data": [
            {"id": "org/flux2-model", "object": "model", "created": 1,
             "capabilities": ["image_generation", "image_editing"]},
            {"id": "/local/snapshot/mage-edit", "object": "model", "created": 2,
             "capabilities": ["image_editing"]},
            {"id": "org/bonsai", "object": "model", "created": 3,
             "capabilities": ["image_generation"]},
            {"id": "org/nocaps", "object": "model", "created": 4}
          ]
        }
        """)
        let caps = await MLXServerModelCapabilities.fetch(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )
        XCTAssertEqual(
            caps.byModelID["org/flux2-model"],
            ["image_generation", "image_editing"]
        )
        XCTAssertEqual(caps.byModelID["/local/snapshot/mage-edit"], ["image_editing"])
        XCTAssertEqual(caps.byModelID["org/bonsai"], ["image_generation"])
        XCTAssertEqual(caps.byModelID["org/nocaps"], [])
    }

    func testFetchReturnsEmptyMapOnServerError() async {
        stubModelsResponse(#"{"object":"list","data":[]}"#, statusCode: 500)
        let caps = await MLXServerModelCapabilities.fetch(
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )
        XCTAssertTrue(caps.byModelID.isEmpty)
    }

    func testFetchReturnsEmptyMapOnUnreachableServer() async {
        MockURLProtocol.responseHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let caps = await MLXServerModelCapabilities.fetch(
            baseURL: URL(string: "http://127.0.0.1:1")!
        )
        XCTAssertTrue(caps.byModelID.isEmpty)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
