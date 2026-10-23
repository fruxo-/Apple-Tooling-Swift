// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VoiceMemosUtils",
    platforms: [.macOS(.v13)],
    products: [
        // The binary is called `vmsearch`; rename freely.
        .executable(name: "voice-memos-utils", targets: ["VoiceMemosUtils"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        // All the logic: database access, date and keyword filtering. No CLI concerns.
        .target(
            name: "VoiceMemosKit"
        ),
        .executableTarget(
            name: "VoiceMemosUtils",
            dependencies: [
                "VoiceMemosKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .testTarget(
            name: "VoiceMemosUtilsTests",
            dependencies: ["VoiceMemosKit", "VoiceMemosUtils"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
    ]
)
