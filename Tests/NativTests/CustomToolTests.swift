import XCTest
@testable import NativServerKit

final class CustomToolTests: XCTestCase {
    func testMakesAStableToolDefinitionFromAnHTTPTool() throws {
        let tool = try CustomTool.make(
            name: "Weather lookup",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomTool.defaultParametersJSON
        )

        XCTAssertEqual(tool.toolName, "custom__weather_lookup")
        XCTAssertEqual(try tool.definition().function.name, "custom__weather_lookup")
    }

    func testRejectsAnInvalidEndpointAndSchema() {
        XCTAssertThrowsError(try CustomTool.make(
            name: "Weather",
            summary: "",
            endpoint: "example.com/weather",
            parametersJSON: CustomTool.defaultParametersJSON
        ))
        XCTAssertThrowsError(try CustomTool.make(
            name: "Weather",
            summary: "",
            endpoint: "https://example.com/weather",
            parametersJSON: "[]"
        ))
    }

    func testSettingsRoundTripCustomTools() throws {
        let tool = try CustomTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomTool.defaultParametersJSON
        )
        let settings = NativSettings(customTools: [tool])
        let decoded = try PropertyListDecoder().decode(
            NativSettings.self,
            from: PropertyListEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.customTools, [tool])
    }

    func testMakesAndPersistsAScriptTool() throws {
        let tool = try CustomTool.make(
            name: "Local lookup",
            summary: "Processes a query locally.",
            kind: .script,
            script: "input=$(cat)\nprintf '%s\\n' \"$input\"",
            scriptLanguage: .shell,
            parametersJSON: CustomTool.defaultParametersJSON
        )
        let data = try PropertyListEncoder().encode(NativSettings(customTools: [tool]))
        let decoded = try PropertyListDecoder().decode(NativSettings.self, from: data)

        XCTAssertEqual(decoded.customTools, [tool])
        XCTAssertEqual(tool.kind, .script)
        XCTAssertEqual(tool.endpoint, "")
        XCTAssertNil(tool.headerName)
    }

    func testDecodesEndpointToolsCreatedBeforeKindsWereAdded() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "name": "Weather",
            "slug": "weather",
            "summary": "Forecasts",
            "endpoint": "https://example.com/weather",
            "parametersJSON": CustomTool.defaultParametersJSON
        ])
        let tool = try JSONDecoder().decode(CustomTool.self, from: data)

        XCTAssertEqual(tool.kind, .endpoint)
        XCTAssertEqual(tool.script, "")
        XCTAssertEqual(tool.scriptLanguage, .python)
    }

    func testHeaderNameIsPersistedWithoutItsValue() throws {
        let tool = try CustomTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomTool.defaultParametersJSON,
            headerName: "Authorization"
        )

        let data = try PropertyListEncoder().encode(NativSettings(customTools: [tool]))
        let serializedSettings = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(serializedSettings.contains("Authorization"))
        XCTAssertFalse(serializedSettings.contains("Bearer secret"))
    }

    func testExecutorPostsArgumentsAndConfiguredHeader() async throws {
        let tool = try CustomTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomTool.defaultParametersJSON,
            headerName: "Authorization"
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        StubURLProtocol.responseData = Data(#"{"forecast":"sunny"}"#.utf8)
        defer { StubURLProtocol.reset() }

        let result = try await CustomToolExecutor.execute(
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
        XCTAssertEqual(
            String(data: try XCTUnwrap(StubURLProtocol.lastRequestBody), encoding: .utf8),
            #"{"query":"Boston"}"#
        )
    }

    func testShellScriptIsCheckedAndExecuted() async throws {
        let tool = try CustomTool.make(
            name: "Echo",
            summary: "Echoes JSON.",
            kind: .script,
            script: "input=$(cat)\nprintf '%s\\n' \"$input\"",
            scriptLanguage: .shell,
            parametersJSON: CustomTool.defaultParametersJSON
        )

        let result = try await CustomToolExecutor.execute(
            tool,
            argumentsJSON: #"{"query":"hello"}"#
        )

        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), #"{"query":"hello"}"#)
    }

    func testShellScriptMustPassSyntaxCheck() async throws {
        let tool = try CustomTool.make(
            name: "Broken",
            summary: "Does not compile.",
            kind: .script,
            script: ")",
            scriptLanguage: .shell,
            parametersJSON: CustomTool.defaultParametersJSON
        )

        do {
            _ = try await CustomToolExecutor.execute(tool, argumentsJSON: "{}")
            XCTFail("Expected the syntax check to fail")
        } catch let error as CustomToolError {
            guard case .scriptFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private struct FixedCredentialStore: CustomToolCredentialStoring {
    let value: String?

    func load(for toolID: UUID) throws -> String? { value }
    func save(_ value: String?, for toolID: UUID) throws {}
}

private final class StubURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var lastRequestBody: Data?
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = requestBody()
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
        lastRequestBody = nil
        responseData = Data()
    }

    private func requestBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBytes { bytes in
                stream.read(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
