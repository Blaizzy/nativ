import XCTest
@testable import nativ

final class ServerClientTests: XCTestCase {

    // MARK: SSE parsing

    func testParsesContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"hello"}}]}"#
        XCTAssertEqual(ServerClient.parseSSE(line), .content("hello"))
    }

    func testParsesDone() {
        XCTAssertEqual(ServerClient.parseSSE("data: [DONE]"), .done)
    }

    func testIgnoresNonDataLines() {
        XCTAssertEqual(ServerClient.parseSSE(""), .ignore)
        XCTAssertEqual(ServerClient.parseSSE(": keep-alive"), .ignore)
    }

    func testIgnoresRoleOnlyDelta() {
        // The opening chunk often carries a role but no content — skip it.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertEqual(ServerClient.parseSSE(line), .ignore)
    }

    func testIgnoresMalformedJSON() {
        XCTAssertEqual(ServerClient.parseSSE("data: {not json"), .ignore)
    }

    // MARK: multipart framing

    func testBuildsMultipartBody() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clip.wav")
        try Data("RIFFxxxx".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let body = try ServerClient.multipartBody(boundary: "B", model: "whisper", fileURL: tmp)
        let text = String(data: body, encoding: .utf8)!

        XCTAssertTrue(text.hasPrefix("--B\r\n"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper\r\n"))
        XCTAssertTrue(text.contains("filename=\"clip.wav\""))
        XCTAssertTrue(text.contains("RIFFxxxx"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }
}
