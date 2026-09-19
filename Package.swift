// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "zumi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JRCore", targets: ["JRCore"]),
        .library(name: "JRSwiftUI", targets: ["JRSwiftUI"]),
        .library(name: "JRClients", targets: ["JRClients"]),
    ],
    targets: [
        .target(name: "JRCore"),
        .target(name: "JRSwiftUI", dependencies: ["JRCore"]),
        .target(name: "JRClients", dependencies: ["JRCore"]),
        .executableTarget(name: "Zumi", dependencies: ["JRCore", "JRSwiftUI", "JRClients"]),
        .testTarget(name: "JRCoreTests", dependencies: ["JRCore"]),
    ]
)
