// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WiFiSync",
    platforms: [.macOS("15.0")],
    products: [.library(name: "WiFiSyncCore", targets: ["WiFiSyncCore"])],
    targets: [
        .target(name: "WiFiSyncCore", path: "Sources/Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "WiFiSyncCoreTests", dependencies: ["WiFiSyncCore"], path: "Tests", resources: [.copy("Fixtures")])
    ]
)
