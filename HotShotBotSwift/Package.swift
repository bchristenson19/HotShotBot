// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HotShotBotSwift",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HotShotBotSwift",
            path: "Sources/HotShotBotSwift"
        ),
        .testTarget(
            name: "HotShotBotSwiftTests",
            dependencies: ["HotShotBotSwift"],
            path: "Tests/HotShotBotSwiftTests"
        ),
    ]
)
