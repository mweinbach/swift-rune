// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "SparkStudio",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SparkStudio", targets: ["SparkStudio"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "SparkStudio",
            dependencies: [
                .product(name: "Rune", package: "swift-rune"),
                .product(name: "RuneKit", package: "swift-rune"),
                .product(name: "RuneMotion", package: "swift-rune"),
            ]
        ),
    ]
)
