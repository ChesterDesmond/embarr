// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EmberBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EmberCore"),
        .executableTarget(name: "EmberBar", dependencies: ["EmberCore"]),
        .testTarget(name: "EmberCoreTests", dependencies: ["EmberCore"]),
    ]
)
