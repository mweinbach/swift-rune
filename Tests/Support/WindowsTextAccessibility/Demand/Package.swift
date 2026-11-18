// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneDemandFixture",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "swift-rune", path: "../../../..")],
    targets: [.executableTarget(name: "RuneDemandFixture", dependencies: [
        .product(name: "Rune", package: "swift-rune")
    ], path: "Fixture")]
)
