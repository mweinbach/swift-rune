// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MiddleScrollProbe",
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(name: "MiddleScrollProbe", dependencies: [.product(name: "Rune", package: "swift-rune")],
                          path: ".", exclude: ["probe.c"], sources: ["main.swift"])
    ]
)
