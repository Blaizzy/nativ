import XCTest
@testable import NativServerKit

final class CustomHTTPToolTests: XCTestCase {
    func testMakesAStableToolDefinitionFromAnHTTPTool() throws {
        let tool = try CustomHTTPTool.make(
            name: "Weather lookup",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON
        )

        XCTAssertEqual(tool.toolName, "custom__weather_lookup")
        XCTAssertEqual(try tool.definition().function.name, "custom__weather_lookup")
    }

    func testRejectsAnInvalidEndpointAndSchema() {
        XCTAssertThrowsError(try CustomHTTPTool.make(
            name: "Weather",
            summary: "",
            endpoint: "example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON
        ))
        XCTAssertThrowsError(try CustomHTTPTool.make(
            name: "Weather",
            summary: "",
            endpoint: "https://example.com/weather",
            parametersJSON: "[]"
        ))
    }

    func testSettingsRoundTripCustomTools() throws {
        let tool = try CustomHTTPTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON
        )
        let settings = NativSettings(customTools: [tool])
        let decoded = try PropertyListDecoder().decode(
            NativSettings.self,
            from: PropertyListEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.customTools, [tool])
    }

    func testHeaderNameIsPersistedWithoutItsValue() throws {
        let tool = try CustomHTTPTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON,
            headerName: "Authorization"
        )

        let data = try PropertyListEncoder().encode(NativSettings(customTools: [tool]))
        let serializedSettings = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(serializedSettings.contains("Authorization"))
        XCTAssertFalse(serializedSettings.contains("Bearer secret"))
    }

    func testExecutorPostsArgumentsAndConfiguredHeader() async throws {
        let tool = try CustomHTTPTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON,
            headerName: "Authorization"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        StubURLProtocol.responseData = Data(#"{"forecast":"sunny"}"#.utf8)
        defer { StubURLProtocol.reset() }

        let result = try await CustomHTTPToolExecutor.execute(
            tool,
            argumentsJSON: #"{"query":"Boston"}"#,
            credentialStore: FixedCredentialStore(value: "Bearer secret"),
            session: session
        )

        XCTAssertEqual(result, #"{"forecast":"sunny"}"#)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), #"{"query":"Boston"}"#)
    }
}

private struct FixedCredentialStore: CustomHTTPToolCredentialStoring {
    let value: String?

    func load(for toolID: UUID) throws -> String? { value }
    func save(_ value: String?, for toolID: UUID) throws {}
}

private final class StubURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lastRequest = nil
        responseData = Data()
    }
}
