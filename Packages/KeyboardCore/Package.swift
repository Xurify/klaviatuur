// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KeyboardCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "KeyboardCore",
            targets: ["KeyboardCore"]
        )
    ],
    targets: [
        .target(
            name: "KeyboardCore",
            path: "Sources/KeyboardCore"
        ),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KeyboardCore"],
            path: "Tests/KeyboardCoreTests"
        )
    ]
)
