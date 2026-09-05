import Foundation
import NativExtensionSDK

enum NativExtensionCatalogPreferences {
    static let overrideKey = "nativExtensionCatalogURLOverride"
    static let productionURL = URL(
        string: "https://blaizzy.github.io/nativ/extensions/catalog.json"
    )!

    static func sourceURL(override value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return productionURL }
        guard let url = URL(string: value), isAllowed(url) else {
            throw NativExtensionCatalogClientError.invalidSourceURL
        }
        return url
    }

    private static func isAllowed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https", url.host != nil {
            return true
        }
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

enum NativExtensionCatalogClientError: LocalizedError, Equatable {
    case invalidSourceURL
    case invalidResponse
    case catalogTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            "Enter an HTTPS URL, or an HTTP localhost URL for development."
        case .invalidResponse:
            "The catalog server returned an invalid response."
        case .catalogTooLarge:
            "The extension catalog is larger than Nativ accepts."
        }
    }
}

struct NativExtensionCatalogClient {
    private static let maximumCatalogSize = 2 * 1_024 * 1_024

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(from sourceURL: URL) async throws -> NativExtensionCatalog {
        let (data, response) = try await session.data(from: sourceURL)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw NativExtensionCatalogClientError.invalidResponse
        }
        guard data.count <= Self.maximumCatalogSize else {
            throw NativExtensionCatalogClientError.catalogTooLarge
        }

        let catalog = try JSONDecoder().decode(NativExtensionCatalog.self, from: data)
        try NativExtensionCatalogValidator.validate(catalog, sourceURL: sourceURL)
        return catalog
    }
}
