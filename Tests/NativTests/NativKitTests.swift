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
                .mcpServer(.catalog(id: "fetch")),
                .mcpServer(.catalog(id: "fetch")),
            ]
        )

        #expect(
            throws: NativKitCatalogError.duplicateComponent(
                kitID: "example",
                componentID: "mcp-catalog:fetch"
            )
        ) {
            try NativKitCatalog(kits: [kit], mcpCatalog: try makeMCPCatalog())
        }
    }

    @Test("Catalog rejects unknown MCP server references")
    func unknownMCPServer() {
        let kit = makeKit(
            id: "example",
            components: [.mcpServer(.catalog(id: "missing"))]
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
            components: [.mcpServer(.catalog(id: "fetch"))]
        )
        let second = makeKit(
            id: "second",
            components: [
                .mcpServer(.catalog(id: "fetch")),
                .skill(id: skill.id),
            ]
        )
        var settings = NativSettings()

        let kitCatalog = try NativKitCatalog(
            kits: [first, second],
            mcpCatalog: mcpCatalog,
            skillDefinitions: [skill]
        )
        NativKitActivation.enableMissing(
            in: first,
            settings: &settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )
        NativKitActivation.enableMissing(
            in: second,
            settings: &settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )

        #expect(settings.mcpServers.count == 1)
        #expect(settings.mcpServers.first?.catalogID == "fetch")
        #expect(settings.mcpServers.first?.isEnabled == true)
        #expect(settings.skills == [skill])
        #expect(
            NativKitActivation.state(
                of: first,
                settings: settings,
                kitCatalog: kitCatalog,
                isExtensionEnabled: { _ in false },
                mcpCatalog: mcpCatalog
            ) == .enabled
        )
        #expect(
            NativKitActivation.state(
                of: second,
                settings: settings,
                kitCatalog: kitCatalog,
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
        let kit = makeKit(id: "example", components: [.skill(id: bundledSkill.id)])
        let kitCatalog = try NativKitCatalog(
            kits: [kit],
            mcpCatalog: .empty,
            skillDefinitions: [bundledSkill]
        )
        var settings = NativSettings(skills: [editedSkill])

        NativKitActivation.enableMissing(
            in: kit,
            settings: &settings,
            kitCatalog: kitCatalog,
            mcpCatalog: .empty
        )

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
                .mcpServer(.catalog(id: "fetch")),
                .skill(id: skill.id),
            ]
        )
        var settings = NativSettings()
        let entry = try #require(mcpCatalog.entry(id: "fetch"))
        mcpCatalog.setEnabled(true, for: entry, in: &settings.mcpServers)

        let snapshot = NativKitActivation.snapshot(
            of: kit,
            settings: settings,
            kitCatalog: try NativKitCatalog(
                kits: [kit],
                mcpCatalog: mcpCatalog,
                skillDefinitions: [skill]
            ),
            extensionName: { $0 },
            isExtensionEnabled: { _ in false },
            mcpCatalog: mcpCatalog
        )

        #expect(snapshot.state == .partial)
        #expect(snapshot.inactivePartNames == ["Example skill"])
    }

    @Test("Runtime resolution reports disabled and missing Kit components")
    func runtimeResolutionReportsUnavailableComponents() throws {
        let mcpCatalog = try makeMCPCatalog()
        let skillID = try #require(UUID(uuidString: "AB000000-0000-4000-8000-000000000004"))
        let skill = NativSkill(
            id: skillID,
            name: "Example skill",
            instructions: "Example instructions",
            isEnabled: true
        )
        let kit = makeKit(
            id: "example",
            components: [
                .mcpServer(.catalog(id: "fetch")),
                .skill(id: skill.id),
                .extensionPackage(id: "com.nativ.example"),
            ]
        )
        let kitCatalog = try NativKitCatalog(
            kits: [kit],
            mcpCatalog: mcpCatalog,
            skillDefinitions: [skill]
        )
        let entry = try #require(mcpCatalog.entry(id: "fetch"))
        var settings = NativSettings(
            mcpServers: [entry.makeConfiguration(isEnabled: false)]
        )

        var resolution = NativKitRuntimeResolver.resolve(
            kitIDs: [kit.id],
            settings: settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )

        #expect(resolution.mcpServers.isEmpty)
        #expect(resolution.skills.isEmpty)
        #expect(resolution.unavailableCapabilities == [
            "Example: Example skill (not configured)",
            "Example: Fetch (disabled)",
        ])

        var disabledSkill = skill
        disabledSkill.isEnabled = false
        settings = NativSettings(skills: [disabledSkill])
        resolution = NativKitRuntimeResolver.resolve(
            kitIDs: [kit.id],
            settings: settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )

        #expect(resolution.unavailableCapabilities == [
            "Example: Example skill (disabled)",
            "Example: Fetch (not configured)",
        ])

        NativKitActivation.enableMissing(
            in: kit,
            settings: &settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )
        resolution = NativKitRuntimeResolver.resolve(
            kitIDs: [kit.id],
            settings: settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )

        #expect(resolution.mcpServers.count == 1)
        #expect(resolution.skills == [skill])
        #expect(resolution.unavailableCapabilities.isEmpty)
    }

    @Test("Routine resolution deduplicates shared capabilities and reports unknown Kits")
    func routineResolutionDeduplicatesSharedCapabilities() throws {
        let mcpCatalog = try makeMCPCatalog()
        let entry = try #require(mcpCatalog.entry(id: "fetch"))
        let skillID = try #require(UUID(uuidString: "AB000000-0000-4000-8000-000000000006"))
        let skill = NativSkill(
            id: skillID,
            name: "Shared skill",
            instructions: "Example instructions",
            isEnabled: true
        )
        let first = makeKit(
            id: "first",
            components: [.mcpServer(.catalog(id: "fetch")), .skill(id: skill.id)]
        )
        let second = makeKit(
            id: "second",
            components: [.mcpServer(.catalog(id: "fetch")), .skill(id: skill.id)]
        )
        let kitCatalog = try NativKitCatalog(
            kits: [first, second],
            mcpCatalog: mcpCatalog,
            skillDefinitions: [skill]
        )
        let server = entry.makeConfiguration()
        let settings = NativSettings(mcpServers: [server], skills: [skill])

        let resolution = NativKitRuntimeResolver.resolve(
            kitIDs: ["first", "missing", "second"],
            settings: settings,
            kitCatalog: kitCatalog,
            mcpCatalog: mcpCatalog
        )

        #expect(resolution.mcpServers == [server])
        #expect(resolution.skills == [skill])
        #expect(resolution.unavailableCapabilities == ["Kit missing (unavailable)"])
    }

    @Test("Kit components use a stable tagged Codable format")
    func componentCodableFormat() throws {
        let configuredID = UUID()
        let customID = UUID()
        let skillID = UUID()
        let components: [NativKitComponent] = [
            .mcpServer(.catalog(id: "fetch")),
            .mcpServer(.configured(id: configuredID)),
            .nativeTool(name: "web_search"),
            .customTool(id: customID),
            .skill(id: skillID),
            .extensionPackage(id: "com.nativ.example"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(components)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""type":"mcpCatalog""#))
        #expect(json.contains(#""type":"mcpConfigured""#))
        #expect(json.contains(#""type":"nativeTool""#))
        #expect(try JSONDecoder().decode([NativKitComponent].self, from: data) == components)
    }

    @Test("Unknown Kit component discriminators fail decoding")
    func unknownComponentTypeFails() {
        let data = Data(#"{"type":"futureCapability","id":"example"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NativKitComponent.self, from: data)
        }
    }

    @Test("User Kit library persists updates and deletion")
    func libraryRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-kit-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kits.json")
        let kit = makeKit(
            id: UUID().uuidString,
            components: [.nativeTool(name: "web_search")]
        )

        let library = NativKitLibrary(storageURL: url)
        try library.upsert(kit)
        #expect(library.userKits == [kit])
        #expect(NativKitLibrary(storageURL: url).userKits == [kit])

        try library.delete(kitID: kit.id)
        #expect(NativKitLibrary(storageURL: url).userKits.isEmpty)
    }

    @Test("Corrupt Kit files are reported and not overwritten")
    func corruptLibraryIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-kit-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Kits.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)

        let library = NativKitLibrary(storageURL: url)

        #expect(library.userKits.isEmpty)
        #expect(library.lastErrorMessage != nil)
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("Tool references activate and resolve without copying tool definitions")
    func toolReferencesActivateAndResolve() throws {
        let custom = try CustomTool.make(
            name: "Example Tool",
            summary: "Example",
            kind: .script,
            script: "print('{}')",
            parametersJSON: CustomTool.defaultParametersJSON
        )
        let kit = makeKit(
            id: "tools",
            components: [
                .nativeTool(name: "web_search"),
                .customTool(id: custom.id),
            ]
        )
        let catalog = try NativKitCatalog.bundled.merging(userKits: [kit])
        var settings = NativSettings(
            customTools: [custom],
            disabledToolNames: ["web_search", custom.toolName]
        )

        NativKitActivation.enableMissing(
            in: kit,
            settings: &settings,
            kitCatalog: catalog,
            mcpCatalog: .empty
        )
        let resolution = NativKitRuntimeResolver.resolve(
            kitIDs: [kit.id],
            settings: settings,
            kitCatalog: catalog,
            mcpCatalog: .empty
        )

        #expect(settings.isToolEnabled("web_search"))
        #expect(settings.isToolEnabled(custom.toolName))
        #expect(resolution.tools == [
            ScheduledTool(provider: .builtIn, name: "web_search"),
            ScheduledTool(provider: .custom(custom.id), name: custom.toolName),
        ])
    }

    @Test("Enabling missing Kit components preserves pinned exposure modes")
    func enablingMissingComponentsPreservesPinnedModes() throws {
        let server = MCPServerConfig(name: "Example MCP", command: "example-mcp")
        let custom = try CustomTool.make(
            name: "Example Tool",
            summary: "Example",
            kind: .script,
            script: "print('{}')",
            parametersJSON: CustomTool.defaultParametersJSON
        )
        let missingTool = ChatSystemMonitorToolRegistry.toolName
        let kit = makeKit(
            id: "preserve-pinned-modes",
            components: [
                .mcpServer(.configured(id: server.id)),
                .nativeTool(name: ChatWebSearchToolRegistry.toolName),
                .nativeTool(name: missingTool),
                .customTool(id: custom.id),
            ]
        )
        var settings = NativSettings(
            mcpServers: [server],
            customTools: [custom],
            disabledToolNames: [missingTool]
        )
        settings.setMCPServerExposureMode(.on, serverID: server.id)
        settings.setToolExposureMode(.on, toolName: ChatWebSearchToolRegistry.toolName)
        settings.setToolExposureMode(.on, toolName: custom.toolName, default: .automatic)

        NativKitActivation.enableMissing(
            in: kit,
            settings: &settings,
            mcpCatalog: .empty
        )

        #expect(settings.mcpServerExposureMode(for: settings.mcpServers[0]) == .on)
        #expect(settings.toolExposureMode(for: ChatWebSearchToolRegistry.toolName) == .on)
        #expect(settings.toolExposureMode(for: custom.toolName, default: .automatic) == .on)
        #expect(settings.toolExposureMode(for: missingTool) == .automatic)
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
