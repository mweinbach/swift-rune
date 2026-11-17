// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LinuxOverlayProbe",
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "OverlayProbe",
            dependencies: [.product(name: "Rune", package: "SwiftRune")]
        )
    ]
)
