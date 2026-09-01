import Foundation
import XCTest

@MainActor
final class ChatProjectStoreTests: XCTestCase {
    func testCreatePersistsCanonicalReadableWritableProject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = ChatProjectStore(storageURL: fixture.storageURL)
        let project = try store.createProject(directoryURL: fixture.projectDirectory)
        let canonicalDirectory = try XCTUnwrap(
            FileWriteAccessPolicy.configuredRootURL(
                rootPath: fixture.projectDirectory.path
            )
        )

        XCTAssertEqual(project.name, "Workspace")
        XCTAssertEqual(project.rootPath, canonicalDirectory.path)
        XCTAssertTrue(store.isRootAvailable(for: project))

        let reloaded = ChatProjectStore(storageURL: fixture.storageURL)
        let reloadedProject = try XCTUnwrap(reloaded.projects.first)
        XCTAssertEqual(reloaded.projects.count, 1)
        XCTAssertEqual(reloadedProject.id, project.id)
        XCTAssertEqual(reloadedProject.name, project.name)
        XCTAssertEqual(reloadedProject.rootPath, project.rootPath)
        XCTAssertEqual(reloadedProject.isCollapsed, project.isCollapsed)
        XCTAssertEqual(reloadedProject.sortOrder, project.sortOrder)
        XCTAssertEqual(
            reloadedProject.createdAt.timeIntervalSince1970,
            project.createdAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            reloadedProject.updatedAt.timeIntervalSince1970,
            project.updatedAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testDuplicateRootIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = ChatProjectStore(storageURL: fixture.storageURL)
        _ = try store.createProject(directoryURL: fixture.projectDirectory)

        XCTAssertThrowsError(
            try store.createProject(directoryURL: fixture.projectDirectory)
        ) { error in
            guard case ChatProjectStoreError.duplicateDirectory = error else {
                return XCTFail("Expected duplicateDirectory, got \(error)")
            }
        }
    }

    func testMissingRootFailsClosedWithoutFallingBackToStandaloneRoots() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = ChatProjectStore(storageURL: fixture.storageURL)
        let project = try store.createProject(directoryURL: fixture.projectDirectory)
        try FileManager.default.removeItem(at: fixture.projectDirectory)
        store.refreshRootAvailability()

        var settings = NativSettings()
        settings.projectToolsEnabled = true
        settings.fileReadRootPath = FileManager.default.homeDirectoryForCurrentUser.path
        settings.fileWriteRootPath = FileManager.default.homeDirectoryForCurrentUser.path
        let scope = store.toolScope(for: project.id, settings: settings)

        XCTAssertFalse(store.isRootAvailable(for: project))
        XCTAssertTrue(scope.isProject)
        XCTAssertNil(scope.rootPath)
        XCTAssertFalse(scope.projectToolsAreAvailable)
    }

    func testProjectToolSwitchIsIndependentFromStandaloneToolSwitches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = ChatProjectStore(storageURL: fixture.storageURL)
        let project = try store.createProject(directoryURL: fixture.projectDirectory)
        var settings = NativSettings()
        settings.disabledToolNames = Array(ChatToolScope.projectToolNames)
        settings.projectToolsEnabled = true

        let enabledScope = store.toolScope(for: project.id, settings: settings)
        XCTAssertTrue(enabledScope.projectToolsAreAvailable)

        settings.projectToolsEnabled = false
        let disabledScope = store.toolScope(for: project.id, settings: settings)
        XCTAssertFalse(disabledScope.projectToolsAreAvailable)
        XCTAssertEqual(disabledScope.rootPath, project.rootPath)
    }

    private func makeFixture() throws -> (
        root: URL,
        projectDirectory: URL,
        storageURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        return (
            root,
            projectDirectory,
            root.appendingPathComponent("Application Support/projects.json")
        )
    }
}
