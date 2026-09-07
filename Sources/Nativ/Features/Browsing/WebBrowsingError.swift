import Foundation

enum WebBrowsingFailureCode: String, Sendable {
    case invalidArguments = "invalid_arguments"
    case missingAPIKey = "missing_api_key"
    case missingEndpoint = "missing_endpoint"
    case credentialAccess = "credential_access"
    case invalidAuthentication = "invalid_authentication"
    case insufficientFunds = "insufficient_funds"
    case planAccess = "plan_access"
    case rateLimited = "rate_limited"
    case providerUnavailable = "provider_unavailable"
    case invalidResponse = "invalid_response"
    case requestFailed = "request_failed"
    case unexpectedFailure = "unexpected_failure"
}

enum WebBrowsingError: LocalizedError {
    case invalidArguments
    case missingAPIKey(WebSearchProvider)
    case missingEndpoint(WebSearchProvider)
    case credentialAccess(WebSearchProvider)
    case invalidResponse(WebSearchProvider)
    case responseTooLarge(WebSearchProvider)
    case requestFailed(WebSearchProvider, Int)
    case providerUnavailable(WebSearchProvider)
    case unexpectedFailure

    var code: WebBrowsingFailureCode {
        switch self {
        case .invalidArguments:
            .invalidArguments
        case .missingAPIKey:
            .missingAPIKey
        case .missingEndpoint:
            .missingEndpoint
        case .credentialAccess:
            .credentialAccess
        case .invalidResponse, .responseTooLarge:
            .invalidResponse
        case .providerUnavailable:
            .providerUnavailable
        case .requestFailed(_, let status):
            switch status {
            case 401: .invalidAuthentication
            case 402: .insufficientFunds
            case 403: .planAccess
            case 429: .rateLimited
            case 500 ... 599: .providerUnavailable
            default: .requestFailed
            }
        case .unexpectedFailure:
            .unexpectedFailure
        }
    }

    var credentialIssue: WebSearchCredentialIssue? {
        switch code {
        case .invalidAuthentication:
            .invalidAuthentication
        case .insufficientFunds:
            .insufficientFunds
        case .planAccess:
            .planAccess
        default:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The browsing request has invalid arguments."
        case .missingAPIKey(let provider):
            "No API key is configured for \(provider.metadata.displayName)."
        case .missingEndpoint(let provider):
            "No instance URL is configured for \(provider.metadata.displayName)."
        case .credentialAccess(let provider):
            "Nativ could not read the \(provider.metadata.displayName) API key from Keychain."
        case .invalidResponse(let provider):
            "\(provider.metadata.displayName) returned an unreadable response."
        case .responseTooLarge(let provider):
            "\(provider.metadata.displayName) returned more data than Nativ accepts."
        case .requestFailed(let provider, let status):
            requestFailureDescription(provider: provider, status: status)
        case .providerUnavailable(let provider):
            "\(provider.metadata.displayName) is currently unavailable."
        case .unexpectedFailure:
            "Browsing failed unexpectedly."
        }
    }

    private func requestFailureDescription(provider: WebSearchProvider, status: Int) -> String {
        let name = provider.metadata.displayName
        switch status {
        case 401:
            return "\(name) rejected the API key."
        case 402:
            return "\(name) reported insufficient funds or credits."
        case 403:
            if provider == .searxng {
                return "\(name) does not allow JSON search responses. Enable the JSON format on this instance."
            }
            return "\(name) denied access for the current plan or API key."
        case 429:
            return "\(name) is rate limiting browsing requests."
        case 500 ... 599:
            return "\(name) is currently unavailable."
        default:
            return "\(name) returned HTTP \(status)."
        }
    }
}
