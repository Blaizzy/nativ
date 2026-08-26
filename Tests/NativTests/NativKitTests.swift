import Foundation
import Testing

@Suite("Kits")
@MainActor
struct NativKitTests {
    @Test("Bundled Kits are validated catalog entries")
    func bundledCatalog() throws {
        let engineering = try #require(NativKitCatalog.bundled.kit(id: "engineering"))
        let research = try #require(NativKitCatalog.bundled.kit(id: "research"))

        #expect(engineering.name == "Engineering")
        #expect(research.name == "Research")
        #expect(engineering.mcpServerIDs.contains("fetch"))
        #expect(research.mcpServerIDs.contains("fetch"))
    }

    @Test("Catalog rejects duplicate Kit identifiers")
    func duplicateKitIdentifiers() {
        let kit = makeKit(id: "example", components: [])

        #expect(throws: NativKitCatalogError.duplicateKitIdentifier("example")) {
            try NativKitCatalog(kits: [kit, kit], mcpCatalog: .empty)
        }
    }

    @Test("Catalog rejects duplicate components within a Kit")
    func duplicateComponents() {
        let kit = makeKit(
            id: "example",
            components: [
                .mcpServer(catalogID: "fetch"),
                .mcpServer(catalogID: "fetch"),
            ]
        )

        #expect(
            throws: NativKitCatalogError.duplicateComponent(
                kitID: "example",
                componentID: "mcp:fetch"
            )
        ) {
            try NativKitCatalog(kits: [kit], mcpCatalog: try makeMCPCatalog())
        }
    }

    @Test("Catalog rejects unknown MCP server references")
    func unknownMCPServer() {
        let kit = makeKit(
            id: "example",
            components: [.mcpServer(catalogID: "missing")]
        )

        #expect(
            throws: NativKitCatalogError.unknownMCPServer(
                kitID: "example",
                catalogID: "missing"
            )
        ) {
            try NativKitCatalog(kits: [kit], mcpCatalog: try makeMCPCatalog())
        }
    }

    @Test("Enabling overlapping Kits is additive and does not duplicate shared components")
    func additiveActivation() throws {
        let mcpCatalog = try makeMCPCatalog()
        let skillID = try #require(UUID(uuidString: "AB000000-0000-4000-8000-000000000001"))
        let skill = NativSkill(
            id: skillID,
            name: "Example skill",
            instructions: "Use the example capability.",
            isEnabled: true
        )
        let first = makeKit(
            id: "first",
            components: [.mcpServer(catalogID: "fetch")]
        )
        let second = makeKit(
            id: "second",
            components: [
                .mcpServer(catalogID: "fetch"),
                .skill(skill),
            ]
        )
        var settings = NativSettings()

        NativKitActivation.enableMissing(in: first, settings: &settings, mcpCatalog: mcpCatalog)
        NativKitActivation.enableMissing(in: second, settings: &settings, mcpCatalog: mcpCatalog)

        #expect(settings.mcpServers.count == 1)
        #expect(settings.mcpServers.first?.catalogID == "fetch")
        #expect(settings.mcpServers.first?.isEnabled == true)
        #expect(settings.skills == [skill])
        #expect(
            NativKitActivation.state(
                of: first,
                settings: settings,
                isExtensionEnabled: { _ in false },
                mcpCatalog: mcpCatalog
            ) == .enabled
        )
        #expect(
            NativKitActivation.state(
                of: second,
                settings: settings,
                isExtensionEnabled: { _ in false },
                mcpCatalog: mcpCatalog
            ) == .enabled
        )
    }

    @Test("Activation preserves an existing skill while enabling it")
    func preservesExistingSkill() throws {
        let id = try #require(UUID(uuidString: "AB000000-0000-4000-8000-000000000002"))
        let bundledSkill = NativSkill(
            id: id,
            name: "Bundled name",
            instructions: "Bundled instructions",
            isEnabled: true
        )
        let editedSkill = NativSkill(
            id: id,
            name: "My name",
            instructions: "My instructions",
            isEnabled: false
        )
        let kit = makeKit(id: "example", components: [.skill(bundledSkill)])
        var settings = NativSettings(skills: [editedSkill])

        NativKitActivation.enableMissing(in: kit, settings: &settings, mcpCatalog: .empty)

        #expect(settings.skills == [
            NativSkill(
                id: id,
                name: "My name",
                instructions: "My instructions",
                isEnabled: true
            ),
        ])
    }

    @Test("State is partial when only some components are enabled")
    func partialState() throws {
        let mcpCatalog = try makeMCPCatalog()
        let skillID = try #require(UUID(uuidString: "AB000000-0000-4000-8000-000000000003"))
        let skill = NativSkill(
            id: skillID,
            name: "Example skill",
            instructions: "Example instructions",
            isEnabled: true
        )
        let kit = makeKit(
            id: "example",
            components: [
                .mcpServer(catalogID: "fetch"),
                .skill(skill),
            ]
        )
        var settings = NativSettings()
        let entry = try #require(mcpCatalog.entry(id: "fetch"))
        mcpCatalog.setEnabled(true, for: entry, in: &settings.mcpServers)

        #expect(
            NativKitActivation.state(
                of: kit,
                settings: settings,
                isExtensionEnabled: { _ in false },
                mcpCatalog: mcpCatalog
            ) == .partial
        )
        #expect(
            NativKitActivation.inactivePartNames(
                of: kit,
                settings: settings,
                extensionName: { $0 },
                isExtensionEnabled: { _ in false },
                mcpCatalog: mcpCatalog
            ) == ["Example skill"]
        )
    }

    private func makeKit(
        id: String,
        components: [NativKitComponent]
    ) -> NativKit {
        NativKit(
            id: id,
            name: id.capitalized,
            summary: "Example Kit",
            symbol: "shippingbox",
            tintName: "blue",
            components: components
        )
    }

    private func makeMCPCatalog() throws -> MCPServerCatalog {
        try MCPServerCatalog(entries: [
            MCPCatalogEntry(
                id: "fetch",
                name: "Fetch",
                summary: "Fetch web content",
                command: "fetch"
            ),
        ])
    }
}
