import Foundation

struct ExternalToolRequirement: Sendable {
    let name: String
    let executableNames: [String]
    let searchDirectories: [String]
}

enum ServerProcessEnvironment {
    static let externalToolRequirements = [
        ExternalToolRequirement(
            name: "FFmpeg",
            executableNames: ["ffmpeg", "ffprobe"],
            searchDirectories: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
    ]

    private static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func augmentedSearchPath(
        inheriting searchPath: String?,
        requirements: [ExternalToolRequirement] = externalToolRequirements,
        isExecutableFile: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String {
        let searchPath = searchPath ?? defaultSearchPath
        var result = searchPath
        var includedDirectories = Set(
            searchPath.split(separator: ":").map(String.init)
        )

        for requirement in requirements {
            guard let directory = requirement.searchDirectories.first(where: { directory in
                let directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
                return requirement.executableNames.allSatisfy { executableName in
                    isExecutableFile(directoryURL.appending(path: executableName).path)
                }
            }) else {
                continue
            }
            guard includedDirectories.insert(directory).inserted else {
                continue
            }
            result += result.isEmpty ? directory : ":\(directory)"
        }
        return result
    }
}
