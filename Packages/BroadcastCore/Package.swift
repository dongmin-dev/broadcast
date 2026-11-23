// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BroadcastCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BroadcastCore", targets: ["BroadcastCore"]),
    ],
    targets: [
        .target(name: "BroadcastCore"),
        .testTarget(name: "BroadcastCoreTests", dependencies: ["BroadcastCore"]),
    ]
)
