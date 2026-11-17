// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneNotificationProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "RuneNotificationProbe", dependencies: [
        .product(name: "RuneNotify", package: "swift-rune")
    ], path: "Sources")]
)
