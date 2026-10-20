// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SafariTabsBackup",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "safari-tabs-backup", targets: ["SafariTabsBackup"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "SafariTabsBackup", dependencies: ["CSQLite"])
    ]
)
