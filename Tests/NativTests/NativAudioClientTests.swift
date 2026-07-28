import XCTest
@testable import NativServerKit

final class NativAudioClientTests: XCTestCase {
    func testTranscriptionRequestUsesExpectedMultipartFields() throws {
        let client = NativAudioClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            apiKey: "test-token"
        )
        let request = client.makeURLRequest(
            audioData: Data([0x00, 0x01, 0x02]),
            fileName: "Voice Recording.wav",
            model: "mlx-community/Qwen3-ASR-0.6B-8bit",
            boundary: "TestBoundary"
        )

        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=TestBoundary"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-token"
        )

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nmlx-community/Qwen3-ASR-0.6B-8bit"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"Voice Recording.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.hasSuffix("\r\n--TestBoundary--\r\n"))
    }

    func testTranscriptionRequestSanitizesMultipartFileName() throws {
        let client = NativAudioClient()
        let request = client.makeURLRequest(
            audioData: Data(),
            fileName: "bad\"\r\nname.m4a",
            model: "speech-model",
            boundary: "TestBoundary"
        )

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("filename=\"bad___name.m4a\""))
        XCTAssertFalse(body.contains("filename=\"bad\"\r\n"))
    }
}
