// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WindowsVideoLayerProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "PlayerProbe",
                                dependencies: [.product(name: "Rune", package: "swift-rune")],
                                path: "Player")]
)
