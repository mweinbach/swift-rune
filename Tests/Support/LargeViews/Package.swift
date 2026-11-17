// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LargeViews",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Port", path: "../../..")],
    targets: [
        .target(name: "LargeViewFixtures", dependencies: [
            .product(name: "Rune", package: "Port"), .product(name: "RuneKit", package: "Port")
        ]),
        .executableTarget(name: "ScrollBench", dependencies: [
            "LargeViewFixtures", .product(name: "Rune", package: "Port"), .product(name: "RuneRef", package: "Port")
        ])
    ]
)
