// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nativ-cli",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "nativ",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/nativ",
            // Swift 5 mode keeps the thin HTTP/JSON glue simple; the CLI is a
            // process-per-invocation tool, not a concurrency-heavy service.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "nativTests",
            dependencies: ["nativ"],
            path: "Tests/nativTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
