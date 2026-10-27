import Foundation

protocol WebBrowsingHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionWebBrowsingHTTPClient: WebBrowsingHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard !request.httpShouldHandleCookies else {
            return try await URLSession.shared.data(for: request)
        }
        let session = URLSession(configuration: .ephemeral, delegate: PublicPageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= 2_000_000 else { throw KeylessWebBrowsingError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw KeylessWebBrowsingError.unavailable }
            data.append(byte)
        }
        return (data, response)
    }
}

enum WebBrowsingAuthentication {
    case bearer
    case header(String)
}

struct WebBrowsingTransport: Sendable {
    private let client: any WebBrowsingHTTPClient
    private let maximumResponseBytes: Int

    init(
        client: any WebBrowsingHTTPClient = URLSessionWebBrowsingHTTPClient(),
        maximumResponseBytes: Int = 2_000_000
    ) {
        self.client = client
        self.maximumResponseBytes = maximumResponseBytes
    }

    func postRequest<Body: Encodable>(
        url: String,
        provider: WebSearchProvider,
        apiKey: String,
        authentication: WebBrowsingAuthentication,
        body: Body,
        timeout: TimeInterval = 20
    ) throws -> URLRequest {
        guard let url = URL(string: url) else {
            throw WebBrowsingError.invalidResponse(provider)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch authentication {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .header(let name):
            request.setValue(apiKey, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func response<Response: Decodable>(
        for request: URLRequest,
        provider: WebSearchProvider
    ) async throws -> Response {
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await client.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebBrowsingError.providerUnavailable(provider)
        }
        guard let response = urlResponse as? HTTPURLResponse else {
            throw WebBrowsingError.invalidResponse(provider)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw WebBrowsingError.requestFailed(provider, response.statusCode)
        }
        guard data.count <= maximumResponseBytes else {
            throw WebBrowsingError.responseTooLarge(provider)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebBrowsingError.invalidResponse(provider)
        }
    }
}

private final class PublicPageRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, WebReadURLPolicy.normalizedURL(url.absoluteString) != nil else {
            completionHandler(nil)
            return
        }
        var next = request
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }
}
