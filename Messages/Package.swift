// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MessagesExporter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "messages-exporter", targets: ["MessagesExporter"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "MessagesExporter", dependencies: ["CSQLite"])
    ]
)
