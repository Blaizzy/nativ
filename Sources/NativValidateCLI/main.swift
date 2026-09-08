import Foundation
import NativExtensionSDK

// Runs Nativ's own package validation outside Nativ, so a catalog's CI reaches
// the same verdict the app would rather than agreeing with a second
// implementation of the rules.

struct Options {
    var packages: [URL] = []
    var hostVersion = "0.0.0"
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        switch argument {
        case "--host-version":
            index += 1
            guard index < arguments.endIndex else {
                throw CLIError.missingValue("--host-version")
            }
            options.hostVersion = arguments[index]
        case "--help", "-h":
            throw CLIError.help
        default:
            guard !argument.hasPrefix("-") else {
                throw CLIError.unknownOption(argument)
            }
            options.packages.append(
                URL(fileURLWithPath: argument, isDirectory: true).standardizedFileURL
            )
        }
        index += 1
    }
    guard !options.packages.isEmpty else { throw CLIError.help }
    return options
}

enum CLIError: Error {
    case help
    case missingValue(String)
    case unknownOption(String)
}

let usage = """
nativ-validate — validate .nativextension packages with Nativ's own rules

USAGE
  nativ-validate [--host-version <semver>] <package.nativextension> ...

  --host-version   Nativ version to validate compatibility against.
                   Defaults to 0.0.0, which accepts any minimum.

Exits non-zero if any package would be refused.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let options: Options
do {
    options = try parseOptions(arguments)
} catch CLIError.missingValue(let option) {
    FileHandle.standardError.write(Data("\(option) needs a value\n".utf8))
    exit(2)
} catch CLIError.unknownOption(let option) {
    FileHandle.standardError.write(Data("unknown option \(option)\n".utf8))
    exit(2)
} catch {
    print(usage)
    exit(2)
}

// Validation never writes, so the destination directory is irrelevant. It is
// required by the installer's shape, not used on this path.
let installer = NativExtensionPackageInstaller(
    fileManager: .default,
    extensionsDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
    hostVersion: options.hostVersion
)

var failures = 0
for packageURL in options.packages {
    let name = packageURL.lastPathComponent
    do {
        let manifest = try installer.validate(packageAt: packageURL)
        let permissions = manifest.permissions.isEmpty
            ? "no permissions"
            : manifest.permissions.map(\.rawValue).sorted().joined(separator: ", ")
        print("ok    \(name) — \(manifest.id) \(manifest.version) (\(permissions))")
    } catch {
        failures += 1
        let reason = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        print("FAIL  \(name) — \(reason)")
    }
}

let checked = options.packages.count
print("\nChecked \(checked) package(s), \(failures) refused")
exit(failures == 0 ? 0 : 1)
