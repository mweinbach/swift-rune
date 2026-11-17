// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneCPUFirstProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .target(name: "CPUProbeDriver", linkerSettings: [
            .linkedLibrary("user32"), .linkedLibrary("gdi32"),
            .linkedLibrary("comctl32"),
        ]),
        .executableTarget(name: "CPUProbe", dependencies: [
            "CPUProbeDriver", .product(name: "Rune", package: "swift-rune"),
        ]),
    ]
)
