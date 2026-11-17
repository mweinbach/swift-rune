// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneStartupProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .target(name: "StartupDriver", linkerSettings: [.linkedLibrary("user32"), .linkedLibrary("comctl32")]),
        .executableTarget(name: "StartupProbe", dependencies: ["StartupDriver", .product(name: "Rune", package: "swift-rune")])
    ]
)
