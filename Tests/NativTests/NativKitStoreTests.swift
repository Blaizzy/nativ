import NativServerKit
import XCTest

@MainActor
final class NativKitStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativKitStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("kits.json")
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testMCPToolSelectionIncludesItsServerReference() throws {
        let serverID = UUID()
        let store = NativKitStore(fileURL: fileURL)
        store.create(UserNativKit(
            name: "Research",
            contents: NativKitContents(mcpSelections: [
                NativKitMCPSelection(
                    server: .configured(serverID),
                    tools: .named(["search"])
                ),
            ])
        ))

        let selection = try XCTUnwrap(store.userKits.first?.contents.mcpSelections.first)
        XCTAssertEqual(selection.server, .configured(serverID))
        XCTAssertEqual(selection.tools, .named(["search"]))
    }

    func testStableReferencesRoundTripWithoutRuntimeNames() {
        let serverID = UUID()
        let store = NativKitStore(fileURL: fileURL)
        store.create(UserNativKit(
            name: "Files",
            contents: NativKitContents(mcpSelections: [
                NativKitMCPSelection(
                    server: .configured(serverID),
                    tools: .named(["read_file"])
                ),
            ])
        ))

        let reloaded = NativKitStore(fileURL: fileURL)
        XCTAssertEqual(
            reloaded.userKits.first?.contents.mcpSelections.first?.tools,
            .named(["read_file"])
        )
    }

    func testDeletedKitIsNoLongerResolvable() {
        let store = NativKitStore(fileURL: fileURL)
        let kit = UserNativKit(
            name: "Temporary",
            contents: NativKitContents(nativeToolNames: ["list_models"])
        )
        store.create(kit)
        XCTAssertNotNil(store.kit(id: kit.id.uuidString))

        store.deleteUserKit(id: kit.id)
        XCTAssertNil(store.kit(id: kit.id.uuidString))
    }

    func testContentsNormalizeDuplicateStableIdentifiers() {
        let toolID = UUID()
        let skillID = UUID()
        let store = NativKitStore(fileURL: fileURL)
        store.create(UserNativKit(
            name: "Deploy",
            contents: NativKitContents(
                customToolIDs: [toolID, toolID],
                skillReferences: [.configured(skillID), .configured(skillID)]
            )
        ))

        XCTAssertEqual(store.userKits.first?.contents.customToolIDs, [toolID])
        XCTAssertEqual(store.userKits.first?.contents.skillReferences, [.configured(skillID)])
    }

    func testMigratesLegacyRuntimeToolNameToStableReference() throws {
        struct LegacyKit: Encodable {
            let id: UUID
            let name: String
            let summary: String
            let mcpServerIDs: [UUID]
            let toolNames: [String]
            let skillIDs: [UUID]
        }
        struct LegacySettings: Encodable { let userKits: [LegacyKit] }

        let server = MCPServerConfig(name: "My Files", command: "files")
        let legacyURL = directory.appendingPathComponent("Settings.plist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(LegacySettings(userKits: [
            LegacyKit(
                id: UUID(),
                name: "Files",
                summary: "",
                mcpServerIDs: [],
                toolNames: ["mcp__My_Files__read_file"],
                skillIDs: []
            ),
        ]))
        try data.write(to: legacyURL)
        let store = NativKitStore(fileURL: fileURL)

        store.migrateLegacySettings(mcpServers: [server], from: legacyURL)

        XCTAssertEqual(
            store.userKits.first?.contents.mcpSelections,
            [NativKitMCPSelection(
                server: .configured(server.id),
                tools: .named(["read_file"])
            )]
        )
    }

    func testBuiltInCatalogHasOnlyCurrentKits() {
        XCTAssertEqual(CustomNativKitCatalog.builtInKits.map(\.id), ["engineering", "research"])
    }

    func testBuiltInEnableStateIsStoredAsAnOverride() {
        let store = NativKitStore(fileURL: fileURL)
        store.setEnabled(false, id: "engineering")

        let reloaded = NativKitStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.kit(id: "engineering")?.isEnabled, false)
        XCTAssertEqual(reloaded.kit(id: "research")?.isEnabled, true)
    }

    func testRoutineResolutionFailsWhenSelectedKitWasRemoved() {
        XCTAssertThrowsError(try RoutineKitResolver.resolve(id: "removed", from: [])) { error in
            XCTAssertEqual(error as? RoutineKitError, .unavailable("removed"))
        }
    }
}
