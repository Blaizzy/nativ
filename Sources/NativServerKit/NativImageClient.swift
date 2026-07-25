import Foundation

public enum NativImageError: Error, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case httpStatus(Int, String)
    case missingImageData

    public var description: String {
        switch self {
        case .invalidResponse:
            return "Invalid image response"
        case .httpStatus(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBody.isEmpty {
                return "Image endpoint returned HTTP \(statusCode)"
            }
            return "Image endpoint returned HTTP \(statusCode): \(trimmedBody)"
        case .missingImageData:
            return "Image response did not include image data"
        }
    }

    public var errorDescription: String? {
        description
    }

    var statusCode: Int? {
        if case .httpStatus(let statusCode, _) = self {
            return statusCode
        }
        return nil
    }
}

public struct MLXImageGenerationRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var prompt: String
    public var n: Int
    public var width: Int
    public var height: Int
    public var steps: Int
    public var seed: Int?
    public var guidance: Double
    public var responseFormat: String
    public var outputFormat: String

    public init(
        model: String,
        prompt: String,
        n: Int = 1,
        width: Int = 1024,
        height: Int = 1024,
        steps: Int = 28,
        seed: Int? = nil,
        guidance: Double = 3.5,
        responseFormat: String = "b64_json",
        outputFormat: String = "png"
    ) {
        self.model = model
        self.prompt = prompt
        self.n = n
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.guidance = guidance
        self.responseFormat = responseFormat
        self.outputFormat = outputFormat
    }

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case n
        case width
        case height
        case steps
        case seed
        case guidance
        case responseFormat = "response_format"
        case outputFormat = "output_format"
    }
}

public struct MLXImageEditRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var prompt: String
    public var image: [String]
    public var n: Int
    public var width: Int?
    public var height: Int?
    public var steps: Int
    public var seed: Int?
    public var guidance: Double
    public var responseFormat: String
    public var outputFormat: String

    public init(
        model: String,
        prompt: String,
        image: [String],
        n: Int = 1,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int = 28,
        seed: Int? = nil,
        guidance: Double = 3.5,
        responseFormat: String = "b64_json",
        outputFormat: String = "png"
    ) {
        self.model = model
        self.prompt = prompt
        self.image = image
        self.n = n
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.guidance = guidance
        self.responseFormat = responseFormat
        self.outputFormat = outputFormat
    }

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case image
        case n
        case width
        case height
        case steps
        case seed
        case guidance
        case responseFormat = "response_format"
        case outputFormat = "output_format"
    }
}

public struct MLXImageResponse: Decodable, Equatable, Sendable {
    public let created: Int
    public let data: [MLXImageResponseData]
    public let outputFormat: String
    public let size: String

    enum CodingKeys: String, CodingKey {
        case created
        case data
        case outputFormat = "output_format"
        case size
    }
}

public struct MLXImageResponseData: Decodable, Equatable, Sendable {
    public let b64JSON: String?
    public let path: String?
    public let revisedPrompt: String?
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let seed: Int

    enum CodingKeys: String, CodingKey {
        case b64JSON = "b64_json"
        case path
        case revisedPrompt = "revised_prompt"
        case mimeType = "mime_type"
        case width
        case height
        case seed
    }
}

public final class NativImageClient {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        timeout: TimeInterval = 1_800
    ) {
        self.baseURL = baseURL
        self.timeout = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func generate(_ request: MLXImageGenerationRequest) async throws -> MLXImageResponse {
        try await post(
            request,
            paths: ["v1/images/generations", "v1/images/generation"]
        )
    }

    public func edit(_ request: MLXImageEditRequest) async throws -> MLXImageResponse {
        try await post(
            request,
            paths: ["v1/images/edits", "v1/images/edit"]
        )
    }

    private func post<Payload: Encodable>(
        _ payload: Payload,
        paths: [String]
    ) async throws -> MLXImageResponse {
        var fallbackError: NativImageError?

        for path in paths {
            do {
                return try await post(payload, path: path)
            } catch let error as NativImageError where error.statusCode == 404 || error.statusCode == 405 {
                fallbackError = error
                continue
            }
        }

        throw fallbackError ?? NativImageError.invalidResponse
    }

    private func post<Payload: Encodable>(
        _ payload: Payload,
        path: String
    ) async throws -> MLXImageResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativImageError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativImageError.httpStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }

        return try decoder.decode(MLXImageResponse.self, from: data)
    }
}
