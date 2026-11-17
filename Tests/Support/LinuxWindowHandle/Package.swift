// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LinuxFloatProbe",
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "FloatApp",
            dependencies: [.product(name: "Rune", package: "SwiftRune")]
        )
    ]
)
