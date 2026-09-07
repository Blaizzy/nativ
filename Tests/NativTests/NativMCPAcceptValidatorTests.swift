import MCP
import XCTest

final class NativMCPAcceptValidatorTests: XCTestCase {
    private let validator = NativMCPAcceptValidator()

    private func post(accept: String?) -> HTTPRequest {
        HTTPRequest(
            method: "POST",
            headers: accept.map { ["Accept": $0] } ?? [:],
            body: Data(),
            path: "/mcp"
        )
    }

    private func context(method: String = "POST") -> HTTPValidationContext {
        HTTPValidationContext(httpMethod: method, isInitializationRequest: true)
    }

    func testClientsThatAcceptJSONAreAllowed() {
        for value in [
            "application/json",
            "application/json, text/event-stream",
            "APPLICATION/JSON",
            "*/*",
            "application/*",
            "text/html, */*;q=0.8",
        ] {
            XCTAssertNil(
                validator.validate(post(accept: value), context: context()),
                "\(value) accepts JSON and must not be refused"
            )
        }
    }

    func testAMissingAcceptHeaderIsAllowed() {
        XCTAssertNil(validator.validate(post(accept: nil), context: context()))
    }

    func testClientsThatRefuseJSONAreTurnedAway() {
        let response = validator.validate(post(accept: "text/html"), context: context())
        XCTAssertEqual(response?.statusCode, 406)
    }

    func testOtherMethodsAreNotChecked() {
        let request = HTTPRequest(method: "GET", headers: ["Accept": "text/html"], path: "/mcp")
        XCTAssertNil(validator.validate(request, context: context(method: "GET")))
    }
}
