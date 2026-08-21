import Foundation
import MCP

struct NativMCPAcceptValidator: HTTPRequestValidator {
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard context.httpMethod.uppercased() == "POST" else {
            return nil
        }
        guard let accept = request.header("Accept")?.lowercased() else {
            return nil
        }
        let acceptsJSON = accept.contains("application/json")
            || accept.contains("*/*")
            || accept.contains("application/*")
        guard !acceptsJSON else {
            return nil
        }
        return .error(
            statusCode: 406,
            MCPError.invalidRequest("This endpoint replies with application/json.")
        )
    }
}
