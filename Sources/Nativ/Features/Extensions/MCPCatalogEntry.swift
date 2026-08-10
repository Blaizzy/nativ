import Foundation
import NativServerKit

struct MCPCatalogEntry: Identifiable, Decodable, Sendable {
    let id: String
    let name: String
    let summary: String
    let command: String
    let arguments: [String]
    let symbol: String
    let tintName: String

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, command
        case arguments = "args"
        case symbol, tint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "server.rack"
        tintName = try container.decodeIfPresent(String.self, forKey: .tint) ?? "accent"
    }

    func makeConfig() -> MCPServerConfig {
        MCPServerConfig(
            name: name,
            command: command,
            arguments: arguments,
            isEnabled: true
        )
    }

    static let catalog: [MCPCatalogEntry] = {
        guard let url = Bundle.main.url(forResource: "MCPCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MCPCatalogEntry].self, from: data)
        else {
            return []
        }
        return entries
    }()
}
