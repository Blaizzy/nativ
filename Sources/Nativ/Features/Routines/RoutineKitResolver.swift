import Foundation

enum RoutineKitError: LocalizedError, Equatable {
    case unavailable(String)
    case incomplete(String, [String])
    case unsupportedBackgroundTool(String)
    case invalidToolCall

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            "The selected Kit “\(name)” is no longer available. Choose another Kit before running this routine."
        case .incomplete(let name, let components):
            "The Kit “\(name)” is not fully available: \(components.joined(separator: ", "))."
        case .unsupportedBackgroundTool(let name):
            "The tool “\(name)” requires an interactive chat and cannot run in a routine."
        case .invalidToolCall:
            "The model returned an invalid tool call."
        }
    }
}

enum RoutineKitResolver {
    static func resolve(id: String, from kits: [NativKit]) throws -> NativKit {
        guard let kit = kits.first(where: { $0.id == id }) else {
            throw RoutineKitError.unavailable(id)
        }
        return kit
    }
}
