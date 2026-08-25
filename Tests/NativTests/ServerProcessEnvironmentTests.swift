import Foundation
import Testing
@testable import NativServerKit

@Suite("Server process environment")
struct ServerProcessEnvironmentTests {
    @Test(
        "Discovers every declared external tool bundle",
        arguments: ServerProcessEnvironment.externalToolBundles
    )
    func discoversDeclaredToolBundle(_ toolBundle: ExternalToolBundle) throws {
        let directory = try #require(toolBundle.searchDirectories.first)
        let installedExecutables = Set(toolBundle.executableNames.map { name in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
        })

        let environment = ServerProcessEnvironment.make(
            inherited: ["PATH": "/usr/bin:/bin"],
            overrides: [:],
            toolBundles: [toolBundle],
            isExecutable: installedExecutables.contains
        )

        #expect(environment["PATH"] == "/usr/bin:/bin:\(directory)")
    }

    @Test("Requires every executable in an external tool bundle")
    func rejectsIncompleteToolBundle() throws {
        let toolBundle = try #require(ServerProcessEnvironment.externalToolBundles.first)
        let directory = try #require(toolBundle.searchDirectories.first)
        let oneExecutable = try #require(toolBundle.executableNames.first)
        let installedExecutables = [
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(oneExecutable)
                .path
        ]

        let environment = ServerProcessEnvironment.make(
            inherited: ["PATH": "/usr/bin:/bin"],
            overrides: [:],
            toolBundles: [toolBundle],
            isExecutable: Set(installedExecutables).contains
        )

        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test("Does not duplicate an existing external tool directory")
    func avoidsDuplicateDirectory() throws {
        let toolBundle = try #require(ServerProcessEnvironment.externalToolBundles.first)
        let directory = try #require(toolBundle.searchDirectories.first)
        let installedExecutables = Set(toolBundle.executableNames.map { name in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
        })

        let environment = ServerProcessEnvironment.make(
            inherited: ["PATH": "/usr/bin:\(directory):/bin"],
            overrides: [:],
            toolBundles: [toolBundle],
            isExecutable: installedExecutables.contains
        )

        #expect(environment["PATH"] == "/usr/bin:\(directory):/bin")
    }

    @Test("Preserves an explicit caller search path")
    func preservesSearchPathOverride() throws {
        let toolBundle = try #require(ServerProcessEnvironment.externalToolBundles.first)
        let directory = try #require(toolBundle.searchDirectories.first)
        let installedExecutables = Set(toolBundle.executableNames.map { name in
            URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
        })

        let environment = ServerProcessEnvironment.make(
            inherited: ["PATH": "/usr/bin:/bin"],
            overrides: ["PATH": "/custom/bin"],
            toolBundles: [toolBundle],
            isExecutable: installedExecutables.contains
        )

        #expect(environment["PATH"] == "/custom/bin")
    }

    @Test("Keeps the bundled Python runtime isolated from app debugging settings")
    func keepsServerSafeguards() {
        let environment = ServerProcessEnvironment.make(
            inherited: [
                "MTL_DEBUG_LAYER": "1",
                "METAL_CAPTURE_ENABLED": "1"
            ],
            overrides: [:],
            toolBundles: [],
            isExecutable: { _ in false }
        )

        #expect(environment["MTL_DEBUG_LAYER"] == nil)
        #expect(environment["METAL_CAPTURE_ENABLED"] == nil)
        #expect(environment["PYTHONNOUSERSITE"] == "1")
        #expect(environment["PYTHONUNBUFFERED"] == "1")
    }
}
