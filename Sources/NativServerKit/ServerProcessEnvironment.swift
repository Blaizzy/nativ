import Foundation

struct ExternalToolBundle: Sendable {
    let name: String
    let executableNames: [String]
    let searchDirectories: [String]
}

enum ServerProcessEnvironment {
    static let externalToolBundles = [
        ExternalToolBundle(
            name: "FFmpeg",
            executableNames: ["ffmpeg", "ffprobe"],
            searchDirectories: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
    ]

    private static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let excludedVariables = [
        "MTL_DEBUG_LAYER",
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_ERROR_MODE",
        "METAL_DEBUG_ENFORCE_VALIDATION",
        "METAL_CAPTURE_ENABLED",
        "MTL_CAPTURE_ENABLED"
    ]

    static func make(
        inherited: [String: String],
        overrides: [String: String],
        toolBundles: [ExternalToolBundle] = externalToolBundles,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> [String: String] {
        var environment = inherited
        environment["PATH"] = augmentedSearchPath(
            inherited["PATH"] ?? defaultSearchPath,
            toolBundles: toolBundles,
            isExecutable: isExecutable
        )
        environment.merge(overrides) { _, newValue in newValue }

        // Xcode enables Metal API validation for the app process and exports
        // these variables to children. Keep validation scoped to Nativ itself.
        for key in excludedVariables {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private static func augmentedSearchPath(
        _ searchPath: String,
        toolBundles: [ExternalToolBundle],
        isExecutable: (String) -> Bool
    ) -> String {
        var result = searchPath
        var includedDirectories = Set(
            searchPath.split(separator: ":").map(String.init)
        )

        for toolBundle in toolBundles {
            guard let directory = toolBundle.searchDirectories.first(where: { directory in
                toolBundle.executableNames.allSatisfy { executableName in
                    let executable = URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(executableName)
                    return isExecutable(executable.path)
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
