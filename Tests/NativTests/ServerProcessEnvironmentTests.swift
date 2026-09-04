import Foundation
import Testing
@testable import NativServerKit

@Suite("Server process environment")
struct ServerProcessEnvironmentTests {
    @Test(
        "Discovers every declared external tool requirement",
        arguments: ServerProcessEnvironment.externalToolRequirements
    )
    func discoversDeclaredTool(_ requirement: ExternalToolRequirement) throws {
        #expect(requirement.name.isEmpty == false)
        #expect(requirement.executableNames.isEmpty == false)
        #expect(requirement.searchDirectories.isEmpty == false)

        for directory in requirement.searchDirectories {
            let directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
            var executablePaths = Set(requirement.executableNames.map {
                directoryURL.appending(path: $0).path
            })
            let baseSearchPath = "/usr/bin:/bin"

            #expect(
                ServerProcessEnvironment.augmentedSearchPath(
                    inheriting: baseSearchPath,
                    requirements: [requirement],
                    isExecutableFile: executablePaths.contains
                ) == "\(baseSearchPath):\(directory)"
            )
            #expect(
                ServerProcessEnvironment.augmentedSearchPath(
                    inheriting: "\(baseSearchPath):\(directory)",
                    requirements: [requirement],
                    isExecutableFile: executablePaths.contains
                ) == "\(baseSearchPath):\(directory)"
            )

            executablePaths.remove(try #require(executablePaths.first))
            #expect(
                ServerProcessEnvironment.augmentedSearchPath(
                    inheriting: baseSearchPath,
                    requirements: [requirement],
                    isExecutableFile: executablePaths.contains
                ) == baseSearchPath
            )
        }
    }
}
