// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Latch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Latch", targets: ["Latch"])
    ],
    targets: [
        .target(
            name: "Latch",
            path: "Sources/Latch"
        ),
        .testTarget(
            name: "LatchTests",
            dependencies: ["Latch"],
            path: "Tests/LatchTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
