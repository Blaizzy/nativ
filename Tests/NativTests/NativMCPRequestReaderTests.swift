import MCP
import XCTest

final class NativMCPRequestReaderTests: XCTestCase {
    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func post(body: String, extraHeaders: String = "") -> Data {
        bytes(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n"
                + extraHeaders
                + "Content-Length: \(body.utf8.count)\r\n\r\n"
                + body
        )
    }

    func testACompleteRequestIsParsed() {
        guard case .request(let request) = NativMCPRequestReader.read(post(body: "{\"a\":1}")) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("host"), "127.0.0.1:8765")
        XCTAssertEqual(request.body, bytes("{\"a\":1}"))
    }

    func testHeaderLookupIgnoresCase() {
        guard case .request(let request) = NativMCPRequestReader.read(
            post(body: "{}", extraHeaders: "Authorization: Bearer nk_abc\r\n")
        ) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(NativMCPRequestReader.bearerToken(in: request), "nk_abc")
    }

    func testATokenWithoutTheBearerPrefixIsAccepted() {
        guard case .request(let request) = NativMCPRequestReader.read(
            post(body: "{}", extraHeaders: "Authorization: nk_raw\r\n")
        ) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(NativMCPRequestReader.bearerToken(in: request), "nk_raw")
    }

    func testHeadersArrivingWithoutTheirBodyAreIncomplete() {
        let partial = bytes("POST /mcp HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"half\"")
        guard case .incomplete = NativMCPRequestReader.read(partial) else {
            return XCTFail("a short body must not be treated as a request")
        }
    }

    func testATruncatedHeaderBlockIsIncomplete() {
        guard case .incomplete = NativMCPRequestReader.read(bytes("POST /mcp HTTP/1.1\r\nHost: x")) else {
            return XCTFail("headers without a terminator must not parse")
        }
    }

    func testABodyLongerThanDeclaredIsTrimmed() {
        let request = bytes("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}trailing")
        guard case .request(let parsed) = NativMCPRequestReader.read(request) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(parsed.body, bytes("{}"))
    }

    func testAnOversizedDeclaredLengthIsRefused() {
        let request = bytes("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n{}")
        guard case .tooLarge = NativMCPRequestReader.read(request) else {
            return XCTFail("a huge declared body must be refused")
        }
    }

    func testAFloodWithoutHeadersIsRefused() {
        let flood = Data(repeating: UInt8(ascii: "x"), count: NativMCPRequestReader.maximumBytes + 1)
        guard case .tooLarge = NativMCPRequestReader.read(flood) else {
            return XCTFail("endless bytes with no header terminator must be refused")
        }
    }

    func testARequestLineWithoutAPathIsMalformed() {
        guard case .malformed = NativMCPRequestReader.read(bytes("POST\r\n\r\n")) else {
            return XCTFail("a request line needs a method and a path")
        }
    }

    func testOnlyTheEndpointPathIsServed() {
        XCTAssertTrue(NativMCPRequestReader.isEndpointPath("/mcp"))
        XCTAssertTrue(NativMCPRequestReader.isEndpointPath("/mcp/"))
        XCTAssertTrue(NativMCPRequestReader.isEndpointPath("/mcp?session=1"))
        XCTAssertFalse(NativMCPRequestReader.isEndpointPath("/mcpother"))
        XCTAssertFalse(NativMCPRequestReader.isEndpointPath("/"))
        XCTAssertFalse(NativMCPRequestReader.isEndpointPath(nil))
    }
}
