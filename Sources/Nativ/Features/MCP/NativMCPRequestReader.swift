import Foundation
import MCP

enum NativMCPRequestOutcome {
    case incomplete
    case request(HTTPRequest)
    case tooLarge
    case malformed
}

struct NativMCPRequestReader {
    static let maximumBytes = 1 << 20

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func read(_ buffer: Data) -> NativMCPRequestOutcome {
        guard let terminator = buffer.range(of: headerTerminator) else {
            return buffer.count > maximumBytes ? .tooLarge : .incomplete
        }

        let head = String(decoding: buffer[..<terminator.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let requestLine = lines.first else {
            return .malformed
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .malformed
        }

        var headers: [String: String] = [:]
        for line in lines {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else {
                continue
            }
            headers[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces)
        }

        let declaredLength = headers
            .first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0
        guard declaredLength <= maximumBytes else {
            return .tooLarge
        }

        let body = buffer[terminator.upperBound...]
        guard body.count >= declaredLength else {
            return .incomplete
        }

        return .request(
            HTTPRequest(
                method: String(parts[0]),
                headers: headers,
                body: Data(body.prefix(declaredLength)),
                path: String(parts[1])
            )
        )
    }

    static func isEndpointPath(_ path: String?) -> Bool {
        guard let path = path?.split(separator: "?").first.map(String.init) else {
            return false
        }
        return path == "/mcp" || path == "/mcp/"
    }

    static func bearerToken(in request: HTTPRequest) -> String? {
        guard let header = request.header("Authorization") else {
            return nil
        }
        let prefix = "Bearer "
        return header.hasPrefix(prefix) ? String(header.dropFirst(prefix.count)) : header
    }
}
