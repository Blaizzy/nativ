import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case server(String)
    case notFound(String)

    var description: String {
        switch self {
        case .usage(let m): return m
        case .server(let m): return "server: \(m)"
        case .notFound(let m): return m
        }
    }
}
