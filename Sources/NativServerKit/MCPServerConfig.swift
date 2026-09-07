import Foundation

public struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Stable identifier for configurations supplied by Nativ's built-in catalog.
    /// Custom configurations leave this nil.
    public var catalogID: String?
    public var name: String
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        catalogID: String? = nil,
        name: String = "",
        command: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.catalogID = catalogID
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isEnabled = isEnabled
    }
}

public enum MCPLaunchCommandError: LocalizedError, Equatable, Sendable {
    case empty
    case unfinishedQuoteOrEscape

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter the command that launches the MCP server."
        case .unfinishedQuoteOrEscape:
            "The launch command contains an unfinished quote or escape."
        }
    }
}

/// A display-friendly command line that Nativ resolves into a `Process`
/// executable and argument array. It is parsed directly and never run by a shell.
public struct MCPLaunchCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    public init(parsing source: String) throws {
        let words = try Self.words(in: source)
        guard let executable = words.first else {
            throw MCPLaunchCommandError.empty
        }
        self.init(executable: executable, arguments: Array(words.dropFirst()))
    }

    public var rendered: String {
        ([executable] + arguments)
            .map(Self.render)
            .joined(separator: " ")
    }

    public var suggestedName: String {
        let filename = URL(fileURLWithPath: executable)
            .deletingPathExtension()
            .lastPathComponent
        return filename.isEmpty ? executable : filename
    }
}

private extension MCPLaunchCommand {
    static func words(in source: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var isEscaping = false
        var hasWord = false

        func finishWord() {
            guard hasWord else { return }
            words.append(word)
            word = ""
            hasWord = false
        }

        for character in source {
            if isEscaping {
                word.append(character)
                hasWord = true
                isEscaping = false
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\" && activeQuote == "\"" {
                    isEscaping = true
                } else {
                    word.append(character)
                    hasWord = true
                }
                continue
            }

            switch character {
            case "'", "\"":
                quote = character
                hasWord = true
            case "\\":
                isEscaping = true
                hasWord = true
            default:
                if character.isWhitespace {
                    finishWord()
                } else {
                    word.append(character)
                    hasWord = true
                }
            }
        }

        guard quote == nil, !isEscaping else {
            throw MCPLaunchCommandError.unfinishedQuoteOrEscape
        }
        finishWord()
        return words
    }

    static func render(_ word: String) -> String {
        guard !word.isEmpty else { return "\"\"" }
        let needsQuotes = word.contains { character in
            character.isWhitespace
                || character == "'"
                || character == "\""
                || character == "\\"
        }
        guard needsQuotes else { return word }

        let escaped = word
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
