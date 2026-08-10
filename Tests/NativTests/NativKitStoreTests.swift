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
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    func testToolSelectionAutomaticallyIncludesItsServer() throws {
        let serverID = UUID()
        let tool = NativKitMCPTool(serverID: serverID, name: "search")
        let store = NativKitStore(fileURL: fileURL)

        store.upsert(UserNativKit(name: "Research", mcpTools: [tool]))

        let saved = try XCTUnwrap(store.userKits.first)
        XCTAssertEqual(saved.mcpServerIDs, [serverID])
        XCTAssertEqual(saved.mcpTools, [tool])
    }

    func testStableToolReferenceRoundTripsWithoutRuntimeSlug() throws {
        let serverID = UUID()
        let tool = NativKitMCPTool(serverID: serverID, name: "read_file")
        let store = NativKitStore(fileURL: fileURL)
        store.upsert(UserNativKit(name: "Files", mcpTools: [tool]))

        let reloaded = NativKitStore(fileURL: fileURL)

        XCTAssertEqual(reloaded.userKits.first?.mcpTools, [tool])
        XCTAssertFalse(reloaded.userKits.first?.mcpTools.first?.name.contains("mcp__") ?? true)
    }

    func testDeletedKitIsNoLongerResolvable() throws {
        let store = NativKitStore(fileURL: fileURL)
        let kit = UserNativKit(name: "Temporary", builtInToolNames: ["list_models"])
        store.upsert(kit)
        XCTAssertNotNil(store.kit(id: kit.id.uuidString))

        store.delete(id: kit.id)

        XCTAssertNil(store.kit(id: kit.id.uuidString))
    }

    func testCustomToolReferencesUseStableIdentifiers() throws {
        let toolID = UUID()
        let store = NativKitStore(fileURL: fileURL)

        store.upsert(UserNativKit(
            name: "Deploy",
            customToolIDs: [toolID, toolID]
        ))

        XCTAssertEqual(store.userKits.first?.customToolIDs, [toolID])
    }

    func testMigratesLegacyRuntimeToolNameToStableReference() throws {
        struct LegacyKit: Encodable {
            let id: UUID
            let name: String
            let summary: String
            let mcpServerIDs: [UUID]
            let toolNames: [String]
            let skillIDs: [UUID]
            let extensionIDs: [String]
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
                skillIDs: [],
                extensionIDs: []
            )
        ]))
        try data.write(to: legacyURL)
        let store = NativKitStore(fileURL: fileURL)

        store.migrateLegacySettings(mcpServers: [server], from: legacyURL)

        XCTAssertEqual(
            store.userKits.first?.mcpTools,
            [NativKitMCPTool(serverID: server.id, name: "read_file")]
        )
        XCTAssertEqual(store.userKits.first?.mcpServerIDs, [server.id])
    }

    func testBuiltInCatalogHasOnlyCurrentKits() {
        XCTAssertEqual(NativKit.builtIns.map(\.id), ["engineering", "research"])
    }

    func testRoutineResolutionFailsWhenSelectedKitWasRemoved() {
        XCTAssertThrowsError(try RoutineKitResolver.resolve(id: "removed", from: [])) { error in
            XCTAssertEqual(error as? RoutineKitError, .unavailable("removed"))
        }
    }
}
