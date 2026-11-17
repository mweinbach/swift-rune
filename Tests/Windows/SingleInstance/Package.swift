// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WindowsSingleInstance",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "HandoffClient",
                                dependencies: [.product(name: "Rune", package: "swift-rune")],
                                path: "Client"),
              .executableTarget(name: "HandoffHost",
                                dependencies: [.product(name: "Rune", package: "swift-rune")],
                                path: "Host")]
)
