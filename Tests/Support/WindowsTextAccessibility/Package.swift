// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneTextFixture",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "RuneTextFixture",
            dependencies: [.product(name: "Rune", package: "swift-rune")],
            path: "Fixture"
        )
    ]
)
