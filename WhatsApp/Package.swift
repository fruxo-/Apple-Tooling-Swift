// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhatsAppExporter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "whatsapp-exporter", targets: ["WhatsAppExporter"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "WhatsAppExporter", dependencies: ["CSQLite"])
    ]
)
