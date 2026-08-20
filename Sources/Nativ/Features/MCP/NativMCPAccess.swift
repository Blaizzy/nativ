import Foundation

enum NativMCPScope: String, Codable, CaseIterable, Sendable {
    case full
    case readOnly

    var title: String {
        switch self {
        case .full:
            "Everything"
        case .readOnly:
            "Read only"
        }
    }
}

struct NativMCPKey: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var secret: String
    var scope: NativMCPScope

    init(id: UUID = UUID(), name: String, scope: NativMCPScope, secret: String = NativMCPKey.newSecret()) {
        self.id = id
        self.name = name
        self.secret = secret
        self.scope = scope
    }

    static func newSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

struct NativMCPAccess: Sendable {
    let keys: [NativMCPKey]
    let readOnlyTools: Set<String>

    static let defaultReadOnlyTools: Set<String> = [
        ChatModelLibraryToolRegistry.toolName,
        ChatSystemMonitorToolRegistry.toolName,
        ChatServerStatsToolRegistry.toolName,
    ]

    func scope(forSecret secret: String?) -> NativMCPScope? {
        guard let secret, !secret.isEmpty else {
            return nil
        }
        return keys.first { matches(secret, $0.secret) }?.scope
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
