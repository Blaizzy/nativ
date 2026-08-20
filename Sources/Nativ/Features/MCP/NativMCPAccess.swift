import Foundation

enum NativMCPCaller: String, Sendable {
    case local
    case outside
}

struct NativMCPAccess: Sendable {
    let localPort: Int
    let outsidePort: Int?
    let localSecret: String
    let outsideSecret: String?
    let outsideAllowedTools: Set<String>

    static let defaultOutsideAllowedTools: Set<String> = [
        ChatModelLibraryToolRegistry.toolName,
        ChatSystemMonitorToolRegistry.toolName,
        ChatServerStatsToolRegistry.toolName,
    ]

    func caller(arrivingOn port: Int, secret: String?) -> NativMCPCaller? {
        guard let secret, !secret.isEmpty else {
            return nil
        }
        if port == localPort {
            return matches(secret, localSecret) ? .local : nil
        }
        if let outsidePort, port == outsidePort {
            guard let outsideSecret else {
                return nil
            }
            return matches(secret, outsideSecret) ? .outside : nil
        }
        return nil
    }

    func permits(_ toolName: String, for caller: NativMCPCaller) -> Bool {
        switch caller {
        case .local:
            return true
        case .outside:
            return outsideAllowedTools.contains(toolName)
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
