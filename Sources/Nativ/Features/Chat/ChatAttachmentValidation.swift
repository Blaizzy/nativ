import Foundation

enum ChatAttachmentValidation: Equatable, Sendable {
    case processing(message: String)
    case ready(extractedCharacterCount: Int?)
    case warning(message: String, extractedCharacterCount: Int?)
    case blocked(message: String)

    var preventsSending: Bool {
        switch self {
        case .processing, .blocked:
            true
        case .ready, .warning:
            false
        }
    }

    var extractedCharacterCount: Int? {
        switch self {
        case .ready(let count), .warning(_, let count):
            count
        case .processing, .blocked:
            nil
        }
    }
}
