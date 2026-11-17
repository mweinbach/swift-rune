// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LinuxSurfaceCompletionProbe",
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(name: "SurfaceApp", dependencies: [.product(name: "Rune", package: "SwiftRune")])
    ]
)
