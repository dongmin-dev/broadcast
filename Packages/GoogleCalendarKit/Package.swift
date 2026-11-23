// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GoogleCalendarKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GoogleCalendarKit", targets: ["GoogleCalendarKit"]),
    ],
    targets: [
        .target(name: "GoogleCalendarKit"),
        .testTarget(
            name: "GoogleCalendarKitTests",
            dependencies: ["GoogleCalendarKit"]
        ),
    ]
)
