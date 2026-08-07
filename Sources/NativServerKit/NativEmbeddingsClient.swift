import Foundation

public enum NativEmbeddingsError: Error {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse
}

public struct NativEmbeddingsClient {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, apiKey: String?, timeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func embed(text: String, model: String) async throws -> [Float] {
        try await first(embed(inputs: [.text(text)], model: model))
    }

    public func embed(dataURL: String, model: String) async throws -> [Float] {
        try await first(embed(inputs: [.image(dataURL)], model: model))
    }

    public func embed(texts: [String], model: String) async throws -> [[Float]] {
        try await embed(inputs: texts.map(Input.text), model: model)
    }

    private func first(_ vectors: [[Float]]) throws -> [Float] {
        guard let vector = vectors.first else {
            throw NativEmbeddingsError.emptyResponse
        }
        return vector
    }

    private enum Input {
        case text(String)
        case image(String)
    }

    private func embed(inputs: [Input], model: String) async throws -> [[Float]] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = RequestBody(model: model, input: inputs.map(InputItem.init))
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NativEmbeddingsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NativEmbeddingsError.httpStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        return decoded.data
            .sorted { $0.index < $1.index }
            .map(\.embedding)
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: [InputItem]
    }

    private enum InputItem: Encodable {
        case text(String)
        case image(String)

        init(_ input: Input) {
            switch input {
            case .text(let value):
                self = .text(value)
            case .image(let value):
                self = .image(value)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
        }

        struct ImageURL: Encodable {
            let url: String
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .image(let value):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURL(url: value), forKey: .imageURL)
            }
        }
    }

    private struct ResponseBody: Decodable {
        let data: [Item]

        struct Item: Decodable {
            let embedding: [Float]
            let index: Int
        }
    }
}
