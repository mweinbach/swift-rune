// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WindowsDecodedVideo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(name: "WindowsVideoConsumption", dependencies: [.product(name: "Rune", package: "SwiftRune")], path: "Player")
    ]
)
