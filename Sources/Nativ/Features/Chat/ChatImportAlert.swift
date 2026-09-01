import Foundation

enum ChatImportAlert: Identifiable, Equatable {
    case originalModel(String)
    case switchModel(String)
    case modelMissing(String)
    case contextExceeded(modelID: String, tokenCount: Int, contextWindow: Int)
    case failed(String)

    var id: String {
        switch self {
        case .originalModel:
            "original-model"
        case .switchModel:
            "switch-model"
        case .modelMissing:
            "model-missing"
        case .contextExceeded:
            "context-exceeded"
        case .failed:
            "failed"
        }
    }

    var title: String {
        switch self {
        case .originalModel:
            "Original model"
        case .switchModel:
            "Switch models?"
        case .modelMissing:
            "Model required"
        case .contextExceeded:
            "Chat is too long to continue"
        case .failed:
            "Couldn’t import chat"
        }
    }

    var message: String {
        switch self {
        case let .originalModel(modelID):
            "This chat was created with \(modelID). You can continue with it or choose another downloaded model."
        case let .switchModel(modelID):
            "This chat was created with \(modelID). You can switch to it or continue with any downloaded model."
        case let .modelMissing(modelID):
            "This chat was created with \(modelID), which is not downloaded. You can find it in Models or continue with another downloaded model."
        case let .contextExceeded(modelID, tokenCount, contextWindow):
            "This chat uses \(tokenCount) tokens, which exceeds \(modelID)’s \(contextWindow)-token context window. You can view it, but not continue it."
        case let .failed(message):
            message
        }
    }
}
