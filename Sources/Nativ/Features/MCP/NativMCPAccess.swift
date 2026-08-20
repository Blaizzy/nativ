import Foundation

enum NativMCPState: Equatable, Sendable {
    case off
    case serving(port: Int)
    case failed(String)
}

enum NativMCPScope: String, Codable, CaseIterable, Sendable {
    case full
    case readOnly

    var title: String {
        switch self {
        case .full:
            "Full access"
        case .readOnly:
            "Read only"
        }
    }
}

struct NativMCPAgent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var scope: NativMCPScope

    init(id: UUID = UUID(), name: String, scope: NativMCPScope) {
        self.id = id
        self.name = name
        self.scope = scope
    }
}

struct NativMCPKey: Equatable, Sendable {
    let agent: NativMCPAgent
    let secret: String

    static func newSecret() -> String {
        "nk_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func masked(_ secret: String) -> String {
        guard secret.count > 7 else {
            return "•••"
        }
        return secret.prefix(3) + String(repeating: "•", count: 10) + secret.suffix(3)
    }
}

struct NativMCPAccess: Sendable {
    let keys: [NativMCPKey]
    let readOnlyTools: Set<String>

    static let defaultReadOnlyTools: Set<String> = [
        NativActionToolProvider.Action.status.rawValue,
        ChatModelLibraryToolRegistry.toolName,
        ChatSystemMonitorToolRegistry.toolName,
        ChatServerStatsToolRegistry.toolName,
    ]

    func key(forSecret secret: String?) -> NativMCPKey? {
        guard let secret, !secret.isEmpty else {
            return nil
        }
        return keys.first { matches(secret, $0.secret) }
    }

    func permits(_ toolName: String, in scope: NativMCPScope) -> Bool {
        switch scope {
        case .full:
            return true
        case .readOnly:
            return readOnlyTools.contains(toolName)
        }
    }

    private func matches(_ provided: String, _ expected: String) -> Bool {
        let provided = Array(provided.utf8)
        let expected = Array(expected.utf8)
        guard provided.count == expected.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in provided.indices {
            difference |= provided[index] ^ expected[index]
        }
        return difference == 0
    }
}
