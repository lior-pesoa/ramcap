// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RAMcap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RAMcapCore", targets: ["RAMcapCore"]),
        .executable(name: "ramcap", targets: ["ramcap"]),
        .executable(name: "RAMcapApp", targets: ["RAMcapApp"]),
    ],
    targets: [
        .target(name: "RAMcapCore"),
        .executableTarget(name: "ramcap", dependencies: ["RAMcapCore"]),
        .executableTarget(name: "RAMcapApp", dependencies: ["RAMcapCore"]),
        .testTarget(name: "RAMcapCoreTests", dependencies: ["RAMcapCore"]),
    ]
)
