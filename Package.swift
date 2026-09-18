// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Latch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Latch", targets: ["Latch"]),
        .library(name: "LatchE2E", targets: ["LatchE2E"]),
    ],
    targets: [
        .target(
            name: "Latch",
            path: "Sources/Latch"
        ),
        .target(
            name: "LatchE2E",
            path: "Sources/LatchE2E"
        ),
        .testTarget(
            name: "LatchTests",
            dependencies: ["Latch"],
            path: "Tests/LatchTests"
        ),
        .testTarget(
            name: "LatchE2ETests",
            dependencies: ["LatchE2E"],
            path: "Tests/LatchE2ETests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
