import Foundation

public struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        command: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isEnabled = isEnabled
    }
}
