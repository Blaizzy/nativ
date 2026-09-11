// swift-tools-version: 6.0
import PackageDescription

// Builds only the parts of Nativ that a catalog's CI needs: the extension
// contracts and the validator that gates an install. Both are Foundation-only,
// so this builds and runs on Linux and the registry can stay on its default
// runners. The app itself is built with Xcode from project.yml.
let package = Package(
    name: "NativExtensionTooling",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NativExtensionSDK", targets: ["NativExtensionSDK"]),
        .executable(name: "nativ-validate", targets: ["NativValidateCLI"]),
    ],
    targets: [
        .target(name: "NativExtensionSDK"),
        .testTarget(name: "NativExtensionSDKTests", dependencies: ["NativExtensionSDK"]),
        .executableTarget(
            name: "NativValidateCLI",
            dependencies: ["NativExtensionSDK"]
        ),
    ]
)
