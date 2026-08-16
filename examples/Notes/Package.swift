// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Notes", targets: ["Notes"])
    ],
    dependencies: [
        .package(name: "Latch", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "Notes",
            dependencies: [
                .product(name: "Latch", package: "Latch")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
